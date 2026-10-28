import Foundation

/// Claude Code in print mode: one process per conversation, fed user turns as
/// stream-json on stdin and answering as stream-json on stdout.
@MainActor
final class ClaudeCodeDriver: AgentDriver {
    private let executable: URL
    private let onEvent: @MainActor (AgentEvent) -> Void
    private var process: Process?
    private var input: FileHandle?
    private var reader: LineReader?
    private var errors: ErrorTail?
    private var sessionID: String?
    /// Model settings the running process was started with.
    private var running: AgentSettings?
    private var turnOpen = false
    private var toolNames: [String: String] = [:]

    init(executable: URL, onEvent: @escaping @MainActor (AgentEvent) -> Void) {
        self.executable = executable
        self.onEvent = onEvent
    }

    func send(_ text: String, settings: AgentSettings) throws {
        // Model and effort are fixed per process; a change restarts it, and
        // --resume carries the conversation over.
        if process?.isRunning == true, running != settings { terminate() }
        try startIfNeeded(settings)
        let turn: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        var line = try JSONSerialization.data(withJSONObject: turn)
        line.append(0x0A)
        turnOpen = true
        try input?.write(contentsOf: line)
    }

    /// Kills the process; the next turn resumes the session in a new one.
    func stop() {
        turnOpen = false
        terminate()
    }

    func shutdown() {
        turnOpen = false
        terminate()
        sessionID = nil
    }

    // MARK: - Process

    private func startIfNeeded(_ settings: AgentSettings) throws {
        if process?.isRunning == true { return }
        let workspace = AgentSupport.workspace(for: .claude)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let mcpConfig = workspace.appendingPathComponent("mcp.json")
        let server: [String: Any] = ["mcpServers": ["disklens": ["command": AgentSupport.mcpCommand,
                                                                  "args": ["--mcp"]]]]
        try JSONSerialization.data(withJSONObject: server).write(to: mcpConfig)

        let p = Process()
        p.executableURL = executable
        p.currentDirectoryURL = workspace
        p.arguments = Self.arguments(mcpConfig: mcpConfig.path, settings: settings, resume: sessionID)
        p.environment = AgentSupport.environment()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        reader = LineReader(stdout) { [weak self] line in self?.handle(line) }
        errors = ErrorTail(stderr)
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(proc) } }
        }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
        running = settings
    }

    private func terminate() {
        guard let p = process else { return }
        process = nil
        input = nil
        running = nil
        if p.isRunning { p.terminate() }
    }

    private func ended(_ p: Process) {
        guard p === process else { return }   // replaced or stopped on purpose
        process = nil
        input = nil
        running = nil
        if turnOpen {
            turnOpen = false
            onEvent(.finished(error: errors?.lastLine ?? ""))
        }
    }

    private static let readOnlyBash = [
        "ls", "du", "df", "stat", "file", "mdls", "readlink", "pgrep", "ps", "lsof",
        "tmutil listlocalsnapshots", "launchctl print", "sysctl vm.swapusage", "defaults read",
    ]

    private static func arguments(mcpConfig: String, settings: AgentSettings, resume: String?) -> [String] {
        let allowed = [
            "mcp__disklens__current_scan", "mcp__disklens__scan", "mcp__disklens__list",
            "mcp__disklens__largest_files", "mcp__disklens__annotate", "mcp__disklens__move_to_trash",
            "Read", "Glob", "Grep", "WebSearch", "WebFetch",
        ] + readOnlyBash.map { "Bash(\($0):*)" }
        var args = [
            "-p", "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--model", settings.model,
            "--effort", settings.effort,
            // The user's own settings may say bypassPermissions or allow more commands
            // (they did: every Bash call ran unasked). Load none of them and pin the
            // mode, so the allow list below is the whole story.
            "--setting-sources", "project",
            "--permission-mode", "default",
            // Reading anywhere on the disk is the point; writing still needs approval,
            // which print mode can't give, so it's refused.
            "--add-dir", "/",
            "--strict-mcp-config", "--mcp-config", mcpConfig,
            // Only these built-ins exist in the session; Bash is further narrowed to
            // read-only commands by the allow list.
            "--tools", "Read,Glob,Grep,Bash,WebSearch,WebFetch",
            "--disallowedTools", "mcp__disklens__open_app",
            "--append-system-prompt", AgentSupport.instructions(for: .claude),
        ]
        if let resume { args += ["--resume", resume] }
        // One argument per rule: some contain spaces ("Bash(tmutil listlocalsnapshots:*)").
        args += ["--allowedTools"] + allowed
        return args
    }

    // MARK: - Stream

    private func handle(_ line: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        // Subagent traffic carries a parent tool id; only the main thread of talk shows.
        if event["parent_tool_use_id"] is String { return }
        switch event["type"] as? String {
        case "system":
            if event["subtype"] as? String == "init" { sessionID = event["session_id"] as? String }

        case "stream_event":
            guard let e = event["event"] as? [String: Any] else { return }
            if e["type"] as? String == "content_block_start",
               (e["content_block"] as? [String: Any])?["type"] as? String == "text" {
                onEvent(.paragraph)
            } else if e["type"] as? String == "content_block_delta", let delta = e["delta"] as? [String: Any] {
                switch delta["type"] as? String {
                case "text_delta": if let t = delta["text"] as? String { onEvent(.text(t)) }
                case "thinking_delta": if let t = delta["thinking"] as? String { onEvent(.thinking(t)) }
                default: break
                }
            }

        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let name = Self.neutralName(block["name"] as? String ?? "")
                let id = block["id"] as? String ?? UUID().uuidString
                toolNames[id] = name
                onEvent(.toolStarted(id: id, name: name, input: block["input"] as? [String: Any] ?? [:]))
            }

        case "user":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let texts = AgentSupport.texts(block["content"])
                let failed = block["is_error"] as? Bool ?? false
                onEvent(.toolFinished(id: id, ok: !failed, summary: AgentSupport.excerpt(texts.joined(separator: "\n"))))
                if toolNames[id] == "disklens.move_to_trash" {
                    let paths = texts.flatMap(AgentSupport.trashedPaths)
                    if !paths.isEmpty { onEvent(.trashed(paths)) }
                }
            }

        case "result":
            turnOpen = false
            if let usage = event["usage"] as? [String: Any] {
                let input = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
                onEvent(.usage(input: input, output: usage["output_tokens"] as? Int ?? 0))
            }
            let failed = event["is_error"] as? Bool ?? false
            onEvent(.finished(error: failed ? event["result"] as? String ?? "" : nil))

        default:
            break
        }
    }

    private static func neutralName(_ tool: String) -> String {
        if tool.hasPrefix("mcp__disklens__") { return "disklens." + tool.dropFirst("mcp__disklens__".count) }
        switch tool {
        case "Bash": return "shell"
        case "Read": return "read"
        case "Glob", "Grep": return "search"
        case "WebSearch", "WebFetch": return "web"
        default: return tool
        }
    }
}
