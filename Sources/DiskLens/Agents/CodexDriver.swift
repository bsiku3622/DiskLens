import Foundation

/// Codex CLI in exec mode: one process per turn (`codex exec`, then
/// `codex exec resume <thread>`), answering as JSON lines on stdout.
@MainActor
final class CodexDriver: AgentDriver {
    private let executable: URL
    private let onEvent: @MainActor (AgentEvent) -> Void
    private var process: Process?
    private var reader: LineReader?
    private var errors: ErrorTail?
    private var threadID: String?
    private var turnOpen = false

    init(executable: URL, onEvent: @escaping @MainActor (AgentEvent) -> Void) {
        self.executable = executable
        self.onEvent = onEvent
    }

    func send(_ text: String, settings: AgentSettings) throws {
        let workspace = AgentSupport.workspace(for: .codex)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var args = ["exec"]
        if threadID != nil { args.append("resume") }
        args += Self.options(settings)
        if let threadID { args.append(threadID) }
        args.append(text)

        let p = Process()
        p.executableURL = executable
        p.currentDirectoryURL = workspace
        p.arguments = args
        p.environment = AgentSupport.environment()
        // With stdin open, exec waits to read more prompt from it.
        p.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        reader = LineReader(stdout) { [weak self] line in self?.handle(line) }
        errors = ErrorTail(stderr)
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(proc) } }
        }
        turnOpen = true
        try p.run()
        process = p
    }

    func stop() {
        turnOpen = false
        terminate()
    }

    func shutdown() {
        stop()
        threadID = nil
    }

    private func terminate() {
        guard let p = process else { return }
        process = nil
        if p.isRunning { p.terminate() }
    }

    private func ended(_ p: Process) {
        guard p === process else { return }   // stopped on purpose
        process = nil
        if turnOpen {
            turnOpen = false
            onEvent(.finished(error: errors?.lastLine ?? ""))
        }
    }

    /// Ignores the user's Codex config (its MCP servers, rules and approvals), runs
    /// the shell read-only, and trusts only this app's MCP server. `exec resume`
    /// takes neither --sandbox nor -m, so everything goes through -c.
    private static func options(_ settings: AgentSettings) -> [String] {
        func config(_ key: String, _ value: String) -> [String] { ["-c", "\(key)=\(value)"] }
        return ["--json", "--ignore-user-config", "--skip-git-repo-check"]
            + config("model", toml(settings.model))
            + config("model_reasoning_effort", toml(settings.effort))
            // Without it exec emits no reasoning items, so there'd be nothing to show.
            + config("model_reasoning_summary", "\"auto\"")
            + config("sandbox_mode", "\"read-only\"")
            + config("approval_policy", "\"never\"")
            + config("mcp_servers.disklens.command", toml(AgentSupport.mcpCommand))
            + config("mcp_servers.disklens.args", "[\"--mcp\"]")
            + config("mcp_servers.disklens.default_tools_approval_mode", "\"approve\"")
            + config("mcp_servers.disklens.disabled_tools", "[\"open_app\"]")
            + config("developer_instructions", toml(AgentSupport.instructions(for: .codex)))
    }

    /// A TOML basic string. JSON's string escaping is valid TOML.
    private static func toml(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())   // strip the [ ]
    }

    // MARK: - Stream

    private func handle(_ line: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let item = event["item"] as? [String: Any] ?? [:]
        let id = item["id"] as? String ?? UUID().uuidString
        switch event["type"] as? String {
        case "thread.started":
            threadID = event["thread_id"] as? String

        case "item.started":
            if let (name, input) = Self.tool(item) {
                onEvent(.toolStarted(id: id, name: name, input: input))
            } else if item["type"] as? String == "reasoning" {
                // Opens the live "Thinking" row; the summary arrives on completion.
                onEvent(.thinking(""))
            }

        case "item.completed":
            switch item["type"] as? String {
            case "agent_message":
                // Codex sends each message whole, not as deltas.
                onEvent(.paragraph)
                onEvent(.text(item["text"] as? String ?? ""))
            case "reasoning":
                if let text = item["text"] as? String, !text.isEmpty { onEvent(.thinking(text + "\n")) }
            case "command_execution":
                let ok = item["status"] as? String == "completed" && (item["exit_code"] as? Int ?? 0) == 0
                onEvent(.toolFinished(id: id, ok: ok,
                                      summary: AgentSupport.excerpt(item["aggregated_output"] as? String ?? "")))
            case "mcp_tool_call":
                let error = (item["error"] as? [String: Any])?["message"] as? String
                let texts = AgentSupport.texts(item["result"])
                onEvent(.toolFinished(id: id, ok: item["status"] as? String == "completed" && error == nil,
                                      summary: AgentSupport.excerpt(error ?? texts.joined(separator: "\n"))))
                if item["tool"] as? String == "move_to_trash" {
                    let paths = texts.flatMap(AgentSupport.trashedPaths)
                    if !paths.isEmpty { onEvent(.trashed(paths)) }
                }
            case "web_search":
                onEvent(.toolFinished(id: id, ok: true, summary: nil))
            default:
                break
            }

        case "turn.completed":
            turnOpen = false
            if let usage = event["usage"] as? [String: Any] {
                onEvent(.usage(input: usage["input_tokens"] as? Int ?? 0,
                               output: usage["output_tokens"] as? Int ?? 0))
            }
            onEvent(.finished(error: nil))

        case "turn.failed", "error":
            guard turnOpen else { return }
            turnOpen = false
            let error = (event["error"] as? [String: Any])?["message"] as? String ?? event["message"] as? String
            onEvent(.finished(error: error ?? ""))

        default:
            break
        }
    }

    /// The neutral tool name and input for an item that is a tool call.
    private static func tool(_ item: [String: Any]) -> (String, [String: Any])? {
        switch item["type"] as? String {
        case "command_execution":
            return ("shell", ["command": innerCommand(item["command"] as? String ?? "")])
        case "mcp_tool_call":
            let server = item["server"] as? String ?? ""
            let tool = item["tool"] as? String ?? ""
            return (server == "disklens" ? "disklens.\(tool)" : tool, item["arguments"] as? [String: Any] ?? [:])
        case "web_search":
            return ("web", ["query": item["query"] as? String ?? ""])
        default:
            return nil
        }
    }

    /// "/bin/zsh -lc 'ls ~/Bufs'" or `/bin/zsh -lc "ls -ld '~/x'"` → the inner command.
    private static func innerCommand(_ command: String) -> String {
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "/bin/sh -c ", "bash -lc "] where command.hasPrefix(shell) {
            let quoted = command.dropFirst(shell.count)
            guard let quote = quoted.first, quote == "'" || quote == "\"", quoted.count >= 2,
                  quoted.last == quote else { continue }
            return String(quoted.dropFirst().dropLast())
        }
        return command
    }
}
