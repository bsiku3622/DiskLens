import Foundation

/// Model Context Protocol server on stdio (newline-delimited JSON-RPC 2.0), so an
/// agent like Claude Code can scan, browse, annotate and trash with DiskLens's own
/// engine. Register it with:
///
///     claude mcp add --scope user disklens -- /Applications/DiskLens.app/Contents/MacOS/DiskLens --mcp
///
/// stdout carries protocol messages only; diagnostics go to stderr.
final class MCPServer {
    private static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let defaultMinSize: Int64 = 1_000_000

    /// Finished scans keyed by root path. A later scan of the same root replaces it.
    private var scans: [String: ScanReport] = [:]
    /// Modification date and root of the app's `current-scan.json` when it was last loaded.
    private var currentScanStamp: Date?
    private var currentScanRoot: String?
    /// The connected agent, credited as the source of its marks.
    private var clientName = "AI"

    func run() async -> Int32 {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let reply = await handle(line) { send(reply) }
        }
        return 0
    }

    // MARK: - JSON-RPC

    private func handle(_ line: String) async -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return error(id: NSNull(), code: -32700, "Parse error")
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        // Notifications (no id) never get a reply.
        guard let id else { return nil }

        switch method {
        case "initialize":
            let client = ((params["clientInfo"] as? [String: Any])?["name"] as? String ?? "").lowercased()
            clientName = client.contains("claude") ? "Claude" : client.contains("codex") ? "Codex" : "AI"
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "disklens", "version": HeadlessScan.appVersion],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let payload = try await call(name, args)
                return result(id: id, ["content": [["type": "text", "text": Self.json(payload)]], "isError": false])
            } catch {
                return result(id: id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            return self.error(id: id, code: -32601, "Method not found: \(method)")
        }
    }

    private func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private func error(id: Any, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    // MARK: - Tools

    struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    private func call(_ name: String, _ args: [String: Any]) async throws -> Any {
        switch name {
        case "current_scan":
            guard let report = refreshCurrentScan() else {
                throw ToolError("The DiskLens app has no finished scan yet. Use scan instead.")
            }
            var out = summary(report)
            out["source"] = "the DiskLens app's own scan — what the user is looking at"
            return out

        case "scan":
            let root = Self.path(args["path"]) ?? FileManager.default.homeDirectoryForCurrentUser.path
            let minSize = Self.megabytes(args["min_size_mb"]) ?? Self.defaultMinSize
            let report = try await scan(root, minSize: minSize)
            return summary(report)

        case "list":
            guard let path = Self.path(args["path"]) else { throw ToolError("path is required") }
            let limit = args["limit"] as? Int ?? 30
            let (node, report) = try await node(at: path)
            return listing(node, limit: limit, scannedAt: report.scannedAt)

        case "largest_files":
            let path = Self.path(args["path"]) ?? FileManager.default.homeDirectoryForCurrentUser.path
            let limit = args["limit"] as? Int ?? 30
            let (node, report) = try await node(at: path)
            return [
                "path": node.path,
                "note": "Only files of at least \(report.minSize.humanBytes) are tracked.",
                "files": node.largestFiles(limit: limit).map { item($0, parentSize: node.size) },
            ]

        case "move_to_trash":
            guard let raw = args["paths"] as? [Any], !raw.isEmpty else { throw ToolError("paths is required") }
            return [
                "results": raw.compactMap(Self.path).map(trash),
                "note": "Items in the Trash still use disk space until the Trash is emptied.",
            ]

        case "annotate":
            let replace = args["replace"] as? Bool ?? false
            let items = try (args["items"] as? [[String: Any]] ?? []).map(Self.annotation).map { item in
                // Without an explicit figure, the item's scanned size is what removing it frees.
                guard item.reclaimBytes == nil,
                      let size = scans.values.lazy.compactMap({ $0.tree.find(item.path)?.size }).first
                else { return item }
                var filled = item
                filled.reclaimBytes = size
                return filled
            }
            let file = try AnnotationStore.write(items, replace: replace, source: clientName)
            return ["file": AnnotationStore.fileURL.path, "count": file.items.count,
                    "note": "The DiskLens app picks up changes within a few seconds."]

        case "open_app":
            let path = Self.path(args["path"])
            try openApp(path)
            return ["opened": path ?? "DiskLens"]

        default:
            throw ToolError("Unknown tool: \(name)")
        }
    }

    /// Picks up the app's latest scan when it changed, unless a newer scan of the same
    /// root is already cached. Returns the freshest scan of the app's root.
    @discardableResult
    private func refreshCurrentScan() -> ScanReport? {
        guard let stamp = CurrentScan.modified else { return nil }
        if stamp != currentScanStamp, let report = CurrentScan.load() {
            currentScanStamp = stamp
            currentScanRoot = report.root
            if (scans[report.root]?.scannedAt ?? .distantPast) < report.scannedAt {
                scans[report.root] = report
            }
        }
        return currentScanRoot.flatMap { scans[$0] }
    }

    private func scan(_ root: String, minSize: Int64) async throws -> ScanReport {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("Not a folder: \(root)")
        }
        let report = try await HeadlessScan.run(URL(fileURLWithPath: root), minSize: minSize, maxDepth: 64)
        scans[root] = report
        return report
    }

    /// The node for `path` from the narrowest cached scan that holds it, scanning the
    /// path itself when none does.
    private func node(at path: String) async throws -> (UsageNode, ScanReport) {
        refreshCurrentScan()
        let covering = scans.values
            .filter { path == $0.root || path.hasPrefix($0.root == "/" ? "/" : $0.root + "/") }
            .sorted { $0.root.count > $1.root.count }
        for report in covering {
            if let node = report.tree.find(path) { return (node, report) }
        }
        if !covering.isEmpty {
            throw ToolError("\(path) is smaller than the scan's min size, so it was folded into its parent's \"other\". Scan it directly for detail.")
        }
        let report = try await scan(path, minSize: Self.defaultMinSize)
        return (report.tree, report)
    }

    private func trash(_ path: String) -> [String: Any] {
        if let reason = Self.trashRefusal(path) { return ["path": path, "ok": false, "error": reason] }
        do {
            let moved = try TrashService.moveToTrash(URL(fileURLWithPath: path))
            for root in scans.keys where path.hasPrefix(root == "/" ? "/" : root + "/") {
                _ = scans[root]?.tree.remove(path)
            }
            return ["path": path, "ok": true, "trashedTo": moved?.path ?? ""]
        } catch {
            return ["path": path, "ok": false, "error": error.localizedDescription]
        }
    }

    /// Guard rails: only inside the home folder or /Applications, never a whole
    /// top-level folder like ~/Library or ~/Documents.
    private static func trashRefusal(_ path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard FileManager.default.fileExists(atPath: path) else { return "No such file or folder" }
        let inHome = path.hasPrefix(home + "/")
        let inApps = path.hasPrefix("/Applications/")
        guard inHome || inApps else { return "Refused: only items inside \(home) or /Applications can be trashed" }
        if inHome, !path.dropFirst(home.count + 1).contains("/") {
            return "Refused: \(path) is a top-level folder of the home directory"
        }
        return nil
    }

    private func openApp(_ path: String?) throws {
        let bundle = Bundle.main.bundleURL
        let app = bundle.pathExtension == "app" ? bundle.path : "DiskLens"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app] + (path.map { ["--args", $0] } ?? [])
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError("open exited with \(process.terminationStatus)") }
    }

    // MARK: - Shaping replies

    private func summary(_ r: ScanReport) -> [String: Any] {
        var out: [String: Any] = [
            "root": r.root,
            "scanned": r.scannedBytes.humanBytes,
            "scannedBytes": r.scannedBytes,
            "files": r.fileCount,
            "seconds": Self.oneDecimal(r.durationSeconds),
            "minSizeTracked": r.minSize.humanBytes,
            "denied": ["fixableByFullDiskAccess": r.denied.fixable, "systemProtected": r.denied.protected],
            "top": r.tree.children.prefix(25).map { item($0, parentSize: r.tree.size) },
        ]
        if let used = r.diskUsedBytes { out["diskActuallyUsed"] = used.humanBytes }
        return out
    }

    private func listing(_ n: UsageNode, limit: Int, scannedAt: Date) -> [String: Any] {
        [
            "path": n.path,
            "size": n.size.humanBytes,
            "bytes": n.size,
            "files": n.files,
            "scannedAt": ISO8601DateFormatter().string(from: scannedAt),
            "children": n.children.prefix(limit).map { item($0, parentSize: n.size) },
            "other": ["size": n.otherSize.humanBytes, "bytes": n.otherSize, "count": n.otherCount],
        ]
    }

    private func item(_ n: UsageNode, parentSize: Int64) -> [String: Any] {
        var out: [String: Any] = [
            "name": n.name,
            "path": n.path,
            "kind": n.isSynthetic ? "volume" : (n.isDirectory ? "folder" : "file"),
            "size": n.size.humanBytes,
            "bytes": n.size,
            "share": Self.oneDecimal(parentSize > 0 ? Double(n.size) / Double(parentSize) * 100 : 0),
        ]
        if n.isDirectory { out["files"] = n.files }
        return out
    }

    /// A Double serializes as 26.199999999999999; a decimal number prints as written.
    private static func oneDecimal(_ x: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", x))
    }

    // MARK: - Argument helpers

    private static func path(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return AnnotationStore.normalize(s)
    }

    private static func megabytes(_ value: Any?) -> Int64? {
        guard let n = value as? Double ?? (value as? Int).map(Double.init), n >= 0 else { return nil }
        return Int64(n * 1_000_000)
    }

    private static func annotation(_ raw: [String: Any]) throws -> Annotation {
        guard let path = path(raw["path"]) else { throw ToolError("each item needs a path") }
        guard let verdict = (raw["verdict"] as? String).flatMap(Verdict.init(rawValue:)) else {
            throw ToolError("verdict must be one of safe, review, keep (\(path))")
        }
        let reclaim = raw["reclaim_bytes"] as? Int64 ?? (raw["reclaim_bytes"] as? Int).map(Int64.init)
        return Annotation(path: path, verdict: verdict, note: raw["note"] as? String ?? "", reclaimBytes: reclaim)
    }

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tool catalog

    private static let instructions = """
    DiskLens measures on-disk usage the way the DiskLens app does: allocated sizes, \
    hidden files included, hardlinks counted once, firmlinks and other volumes never \
    double-counted. Start with current_scan: when the app has scanned, it is exactly \
    what the user is looking at, at no cost. Otherwise call scan once (your home \
    folder, or "/" for the whole disk). Then browse with list and largest_files — they \
    read the cached scan, including the app's. Use annotate to \
    show your verdicts to the user inside the app. move_to_trash is recoverable but \
    frees no space until the Trash is emptied.
    """

    private static let tools: [[String: Any]] = [
        [
            "name": "current_scan",
            "description": "The DiskLens app's latest scan — the folder the user is looking at in the app — with totals and the largest top-level items. No scanning needed; list and largest_files read it too. Fails if the app hasn't scanned yet.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "scan",
            "description": "Scan a folder with DiskLens and cache the result for list and largest_files. Use \"/\" for the whole disk. A home-folder scan can take a minute or two. Returns totals and the largest top-level items.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Folder to scan. Defaults to the home folder. ~ is expanded."],
                    "min_size_mb": ["type": "number", "description": "Items smaller than this are folded into their folder's \"other\" total. Default 1."],
                ],
            ],
        ],
        [
            "name": "list",
            "description": "List a folder's children from the cached scan, largest first, with size and share of the folder. Scans the folder first if no cached scan covers it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Folder to list."],
                    "limit": ["type": "integer", "description": "Maximum children to return. Default 30."],
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "largest_files",
            "description": "The largest individual files anywhere under a folder, from the cached scan.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Folder to search. Defaults to the home folder."],
                    "limit": ["type": "integer", "description": "Maximum files to return. Default 30."],
                ],
            ],
        ],
        [
            "name": "move_to_trash",
            "description": "Move files or folders to the Trash (recoverable). Only items inside the home folder or /Applications, and never a whole top-level home folder such as ~/Library. Space is freed only when the Trash is emptied. Confirm with the user first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths to trash."],
                ],
                "required": ["paths"],
            ],
        ],
        [
            "name": "annotate",
            "description": "Mark items for the user to see in the DiskLens app: a badge in the contents list, an outline in the sunburst, and a list in the app's banner. verdict: safe (can be removed), review (the user should decide), keep (should stay). The note is shown as the reason.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string"],
                                "verdict": ["type": "string", "enum": ["safe", "review", "keep"]],
                                "note": ["type": "string", "description": "One short sentence, in the user's language."],
                                "reclaim_bytes": ["type": "integer", "description": "Space a cleanup would free, if different from the item's size."],
                            ],
                            "required": ["path", "verdict", "note"],
                        ],
                    ],
                    "replace": ["type": "boolean", "description": "Clear earlier marks first. With an empty items list, clears all marks."],
                ],
                "required": ["items"],
            ],
        ],
        [
            "name": "open_app",
            "description": "Open the DiskLens app so the user can see the chart and your annotations. With a path, the app scans that folder when it isn't already running.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Folder to scan on launch."],
                ],
            ],
        ],
    ]
}
