import Foundation

/// A size-pruned, serializable copy of a scanned tree.
///
/// Children below the threshold fold into `otherSize`/`otherCount`, so a whole-disk
/// scan of millions of files becomes a few thousand nodes — small enough for a JSON
/// export or an MCP reply, and cheap to keep in memory between tool calls.
struct UsageNode: Codable, Sendable {
    let name: String
    let path: String
    private(set) var size: Int64
    private(set) var files: Int
    let isDirectory: Bool
    /// A volume sized from the mount table rather than walked (see `VolumeMap`).
    let isSynthetic: Bool
    private(set) var children: [UsageNode]
    /// Bytes and item count of children too small (or too deep) to keep.
    private(set) var otherSize: Int64
    private(set) var otherCount: Int

    init(_ node: FileNode, minSize: Int64, depthLeft: Int) {
        name = node.name
        path = node.url.path
        size = node.size
        files = node.isDirectory ? node.fileCount : 1
        isDirectory = node.isDirectory
        isSynthetic = node.isSynthetic
        var kept: [UsageNode] = []
        var restSize: Int64 = 0
        var restCount = 0
        for child in node.children.sorted(by: { $0.size > $1.size }) {
            if depthLeft > 0, child.size >= minSize {
                kept.append(UsageNode(child, minSize: minSize, depthLeft: depthLeft - 1))
            } else {
                restSize += child.size
                restCount += 1
            }
        }
        children = kept
        otherSize = restSize
        otherCount = restCount
    }

    /// The kept node at `path`, if this tree reaches it.
    func find(_ target: String) -> UsageNode? {
        if target == path { return self }
        guard let next = children.first(where: { Self.leads($0, to: target, from: path) }) else { return nil }
        return next.find(target)
    }

    /// Drops the node at `path` and rolls its bytes out of every ancestor.
    /// Returns false when the path was folded into "other" and can't be adjusted.
    mutating func remove(_ target: String) -> Bool {
        guard let idx = children.firstIndex(where: { Self.leads($0, to: target, from: path) }) else {
            return false
        }
        let freedSize: Int64
        let freedFiles: Int
        if children[idx].path == target {
            let removed = children.remove(at: idx)
            freedSize = removed.size
            freedFiles = removed.files
        } else {
            let before = (children[idx].size, children[idx].files)
            guard children[idx].remove(target) else { return false }
            freedSize = before.0 - children[idx].size
            freedFiles = before.1 - children[idx].files
        }
        size -= freedSize
        files -= freedFiles
        return true
    }

    /// The largest kept files anywhere below this node.
    func largestFiles(limit: Int) -> [UsageNode] {
        var out: [UsageNode] = []
        func collect(_ n: UsageNode) {
            if !n.isDirectory { out.append(n); return }
            n.children.forEach(collect)
        }
        children.forEach(collect)
        return Array(out.sorted { $0.size > $1.size }.prefix(limit))
    }

    /// Whether descending into `child` can reach `target`. The synthetic volume group
    /// shares its parent's path, so it's only a match for paths that name a volume.
    private static func leads(_ child: UsageNode, to target: String, from parentPath: String) -> Bool {
        if child.path == target { return true }
        if child.path == parentPath { return false }
        return target.hasPrefix(child.path.hasSuffix("/") ? child.path : child.path + "/")
    }
}

/// One finished scan, as exported by `--export` and cached by the MCP server.
struct ScanReport: Codable, Sendable {
    struct Denied: Codable, Sendable {
        /// Folders Full Disk Access would unlock.
        let fixable: Int
        /// Root-owned folders no permission opens.
        let protected: Int
        let samplePaths: [String]
    }

    let app: String
    let version: String
    let root: String
    let scannedAt: Date
    let durationSeconds: Double
    /// Sum of allocated sizes; runs above `diskUsedBytes` where APFS clones share blocks.
    let scannedBytes: Int64
    let fileCount: Int
    /// What the volume really holds (`df` Used) — only when the scan root is a volume root.
    let diskUsedBytes: Int64?
    let minSize: Int64
    let denied: Denied
    var tree: UsageNode
}

/// Runs the scan engine without the UI and returns a pruned report.
enum HeadlessScan {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static func run(_ root: URL, minSize: Int64, maxDepth: Int) async throws -> ScanReport {
        final class Box: @unchecked Sendable {
            var tree: FileNode?
            var progress = ScanProgress()
        }
        let box = Box()
        let started = Date()
        let volumes = VolumeMap(scanRoot: root)
        let scanner = Scanner(root: root,
                              volumes: volumes,
                              onProgress: { box.progress = $0 },
                              onSnapshot: { _ in },
                              onComplete: { box.tree = $0 },
                              liveSnapshots: false)
        try await scanner.run()
        guard let tree = box.tree else { throw ScanError.cancelled }
        return report(tree, volumes: volumes, progress: box.progress, startedAt: started,
                      minSize: minSize, maxDepth: maxDepth)
    }

    /// Prunes a finished tree into a report. Shared by headless runs and the app,
    /// which hands its own scans to the MCP server (see `CurrentScan`).
    static func report(_ tree: FileNode, volumes: VolumeMap, progress p: ScanProgress,
                       startedAt started: Date, minSize: Int64, maxDepth: Int) -> ScanReport {
        ScanReport(
            app: "DiskLens",
            version: appVersion,
            root: tree.url.path,
            scannedAt: started,
            durationSeconds: Date().timeIntervalSince(started),
            scannedBytes: tree.size,
            fileCount: tree.fileCount,
            diskUsedBytes: volumes.scanRootIsVolumeRoot ? volumes.containerUsedBytes : nil,
            minSize: minSize,
            denied: .init(fixable: p.deniedFixable, protected: p.deniedProtected, samplePaths: p.deniedPaths),
            tree: UsageNode(tree, minSize: minSize, depthLeft: maxDepth))
    }

    /// "20M", "1.5G", "500K" or plain bytes. Decimal units, matching Finder.
    static func parseSize(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3),
                                         ("T", 1e12), ("G", 1e9), ("M", 1e6), ("K", 1e3), ("B", 1)]
        for (suffix, factor) in units where t.hasSuffix(suffix) {
            guard let n = Double(t.dropLast(suffix.count)) else { return nil }
            return Int64(n * factor)
        }
        return Int64(t)
    }
}
