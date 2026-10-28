import Foundation

/// A coding-agent CLI the sidebar can talk through.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private var executableName: String { self == .claude ? "claude" : "codex" }

    private var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .claude:
            return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                    "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        case .codex:
            return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                    "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex"]
        }
    }

    /// The installed CLI, or nil. Looked up once per launch.
    @MainActor
    func locate() -> URL? {
        if let cached = Self.located[self] { return cached }
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:)) ?? loginShellLookup()
        Self.located[self] = found
        return found
    }

    @MainActor private static var located: [AgentKind: URL?] = [:]

    /// `whence -p` returns the file even where the name is a shell alias.
    private func loginShellLookup() -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "whence -p \(executableName)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    @MainActor
    func makeDriver(executable: URL, onEvent: @escaping @MainActor (AgentEvent) -> Void) -> AgentDriver {
        switch self {
        case .claude: return ClaudeCodeDriver(executable: executable, onEvent: onEvent)
        case .codex: return CodexDriver(executable: executable, onEvent: onEvent)
        }
    }
}

/// What a driver reports while answering, in agent-neutral terms.
enum AgentEvent {
    /// Streamed answer text to append.
    case text(String)
    /// The next answer text starts a new paragraph.
    case paragraph
    /// Streamed reasoning to append (Claude's thinking, Codex's reasoning summary).
    case thinking(String)
    /// A tool call began, by neutral name: "disklens.list", "shell", "read", "search", "web".
    case toolStarted(id: String, name: String, input: [String: Any])
    /// A tool call ended; `summary` is a short excerpt of its result.
    case toolFinished(id: String, ok: Bool, summary: String?)
    /// Paths the agent moved to the Trash, to drop from the chart.
    case trashed([String])
    /// Token counts for the turn.
    case usage(input: Int, output: Int)
    /// The turn is over; `error` explains a failure.
    case finished(error: String?)
}

/// Runs one agent CLI for one conversation.
@MainActor
protocol AgentDriver: AnyObject {
    /// Starts a turn with the given model settings. Events arrive through the
    /// driver's `onEvent`.
    func send(_ text: String, settings: AgentSettings) throws
    /// Ends the current turn early; the next `send` continues the same conversation.
    func stop()
    /// Ends the conversation and any process behind it.
    func shutdown()
}

/// What both drivers share: where they run, what they're told, how output is read.
enum AgentSupport {
    /// Each agent gets its own working folder, so its sessions stay apart from the
    /// user's projects.
    static func workspace(for kind: AgentKind) -> URL {
        AnnotationStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("Agents/\(kind.rawValue)")
    }

    /// This app in `--mcp` mode, so the agent reads the scan the user is looking at.
    static var mcpCommand: String {
        Bundle.main.executablePath ?? "/Applications/DiskLens.app/Contents/MacOS/DiskLens"
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Apps start with a bare PATH; the CLIs (Codex is a node script) and their
        // shell tools need the usual places.
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        // Launched from inside an agent session, these would mark it as nested.
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        return env
    }

    /// Paths reported as trashed in a `move_to_trash` reply.
    static func trashedPaths(inReply text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = reply["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { $0["ok"] as? Bool == true ? $0["path"] as? String : nil }
    }

    /// Text parts of an MCP tool result, however the CLI wraps them.
    static func texts(_ content: Any?) -> [String] {
        if let s = content as? String { return [s] }
        if let dict = content as? [String: Any] { return texts(dict["content"]) }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    /// The human part of an error the CLI may hand over as raw API JSON
    /// (`{"type":"error","error":{"message":"…"}}`).
    static func readableError(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return text }
        return (json["error"] as? [String: Any])?["message"] as? String ?? json["message"] as? String ?? text
    }

    /// The first few lines of a tool's output, for the step's detail view.
    static func excerpt(_ text: String, lines: Int = 8, characters: Int = 600) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var out = trimmed.split(separator: "\n", omittingEmptySubsequences: false).prefix(lines)
            .joined(separator: "\n")
        if out.count > characters { out = String(out.prefix(characters)) }
        return out.count < trimmed.count ? out + "\n…" : out
    }

    /// The agent's standing instructions: how to behave in the sidebar, plus the
    /// user's storage-cleanup skill as a playbook.
    static func instructions(for kind: AgentKind) -> String {
        let language = Lang.current == .ko ? "Korean" : "English"
        var prompt = """
        You are \(kind.displayName) inside DiskLens, a macOS disk-usage app, answering in \
        its sidebar next to a sunburst chart and a contents list of the user's latest \
        scan. Each user message ends with "(DiskLens — …)" naming the scan root and what \
        they're viewing.

        - Use the DiskLens tools. Start from current_scan (the app's own scan, no \
        rescanning), then list and largest_files. Only call scan for places the app \
        didn't cover.
        - Explain what items are, why they're large, and whether removing them is safe. \
        Check before judging (is the owning app running, is it a symlink target, does it \
        regenerate). For a full review, follow step 1 of the playbook below.
        - Mark verdicts with the annotate tool (safe / review / keep, one-sentence note); \
        the app shows them as badges and outlines.
        - Deleting: only when the user asks in this chat. List exactly what will move, \
        then use move_to_trash. You cannot delete permanently and your shell is \
        read-only; say that space returns once the Trash is emptied.
        - You can't show choice dialogs; ask in plain text with numbered options.
        - Keep replies short and skimmable: short paragraphs and "- " lists. No tables, \
        no headings above ###. Write sizes like "12.3 GB" and paths with ~.
        - Reply in \(language).
        """
        if let playbook = storageCleanupPlaybook {
            prompt += """


            The user's storage-cleanup skill follows as your playbook. Inside this sidebar the \
            rules above win: no scripts, no rm, no choice dialogs, no logs — use the DiskLens \
            tools, and the Trash for deleting.

            \(playbook)
            """
        }
        return prompt
    }

    /// The storage-cleanup skill and its hotspot list. The agents run without the
    /// user's own settings (see the drivers), which also hides user skills, so the
    /// skill's text travels in the instructions. Re-read for every conversation.
    private static var storageCleanupPlaybook: String? {
        let skill = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/storage-cleanup")
        guard var body = try? String(contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8)
        else { return nil }
        // Drop the YAML frontmatter.
        if body.hasPrefix("---"),
           let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
            body = String(body[end.upperBound...])
        }
        if let hotspots = try? String(contentsOf: skill.appendingPathComponent("references/hotspots.md"),
                                      encoding: .utf8) {
            body += "\n\n" + hotspots
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Splits a pipe's output into lines and hands each to `onLine` on the main queue,
/// in order (a Task per chunk wouldn't keep the order).
final class LineReader: @unchecked Sendable {
    private var buffer = Data()

    init(_ pipe: Pipe, onLine: @escaping @MainActor (Data) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            // At EOF the handler would keep firing with empty reads.
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.buffer.append(data)
                    while let newline = self.buffer.firstIndex(of: 0x0A) {
                        let line = self.buffer[self.buffer.startIndex..<newline]
                        self.buffer.removeSubrange(self.buffer.startIndex...newline)
                        if !line.isEmpty { onLine(Data(line)) }
                    }
                }
            }
        }
    }
}

/// Keeps the end of a process's stderr for error messages.
final class ErrorTail: @unchecked Sendable {
    private(set) var text = ""

    init(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self.text = String((self.text + chunk).suffix(2000)) }
        }
    }

    var lastLine: String {
        text.split(separator: "\n").last.map(String.init) ?? ""
    }
}
