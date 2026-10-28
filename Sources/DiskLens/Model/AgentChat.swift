import SwiftUI

/// The sidebar conversation with a coding agent (Claude Code or Codex) about the scan.
///
/// Nothing is sent on the user's behalf: the toolbar button and "Ask AI" pick an
/// agent if none is running yet, then only fill the composer. The user sends.
@MainActor
final class AgentChat: ObservableObject {
    static let shared = AgentChat()

    /// One piece of an answer, in the order it happened.
    struct Segment: Identifiable {
        enum Kind { case thinking, step, text }
        enum State { case running, done, failed }
        let id = UUID()
        let kind: Kind
        /// Thinking text, answer text, or the step's label.
        var text: String
        /// A step's result excerpt.
        var detail: String?
        var state: State = .running
        /// The tool call a step stands for.
        var toolID: String?
        let started = Date()
        var ended: Date?
    }

    struct Message: Identifiable {
        /// `notice` reports a problem; `info` narrates what the app is doing.
        enum Role { case user, assistant, notice, info }
        let id = UUID()
        let role: Role
        /// The user's prompt or a notice; answers keep their content in `segments`.
        var text = ""
        var segments: [Segment] = []
        let started = Date()
        var ended: Date?
        var inputTokens = 0
        var outputTokens = 0

        /// The answer's text, without thinking or steps (for copying).
        var answer: String {
            segments.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
        }
    }

    /// What confirming the agent picker leads to.
    enum PickPurpose {
        /// Open the chat with a prompt ready to send.
        case chat
        /// Scan the whole disk, then send the analysis right away.
        case freeUpSpace
    }

    @Published var isVisible = false
    /// The agent picker popover, shown on the button that asked for it.
    @Published var pickerShown = false
    @Published private(set) var pickPurpose = PickPurpose.chat
    /// "Free up space with AI" is scanning; the analysis goes out when it's done.
    @Published private(set) var waitingForScan = false
    /// The agent for the next conversation; fixed once one starts.
    @Published var kind: AgentKind {
        didSet {
            UserDefaults.standard.set(kind.rawValue, forKey: "agentKind")
            settings = Self.savedSettings(for: kind)
        }
    }
    /// Model and reasoning level, remembered per agent. Takes effect from the next turn.
    @Published var settings: AgentSettings {
        didSet {
            UserDefaults.standard.set(settings.model, forKey: "agentModel.\(kind.rawValue)")
            UserDefaults.standard.set(settings.effort, forKey: "agentEffort.\(kind.rawValue)")
        }
    }
    /// The composer's text.
    @Published var draft = ""
    @Published private(set) var started = false
    @Published private(set) var messages: [Message] = []
    /// A turn is in flight.
    @Published private(set) var isRunning = false
    /// Bumped on every streamed change so the transcript can follow along.
    @Published private(set) var tick = 0

    private var driver: AgentDriver?
    /// What the composer gets once the picker is confirmed.
    private var prefillAfterPick = ""

    private init() {
        let kind = AgentKind(rawValue: UserDefaults.standard.string(forKey: "agentKind") ?? "") ?? .claude
        self.kind = kind
        settings = Self.savedSettings(for: kind)
    }

    func isInstalled(_ kind: AgentKind) -> Bool { kind.locate() != nil }

    /// Picks a model, keeping the reasoning level when the model supports it.
    func selectModel(_ model: ModelChoice) {
        let effort = model.efforts.contains(settings.effort) ? settings.effort : model.defaultEffort
        settings = AgentSettings(model: model.id, effort: effort)
    }

    var currentModel: ModelChoice? { kind.models().first { $0.id == settings.model } }

    /// The last choice for `kind`, as long as its model is still on offer.
    private static func savedSettings(for kind: AgentKind) -> AgentSettings {
        let fallback = kind.userDefaults
        let defaults = UserDefaults.standard
        guard let model = defaults.string(forKey: "agentModel.\(kind.rawValue)"),
              let choice = kind.models().first(where: { $0.id == model }) else { return fallback }
        let effort = defaults.string(forKey: "agentEffort.\(kind.rawValue)") ?? choice.defaultEffort
        return AgentSettings(model: model, effort: choice.efforts.contains(effort) ? effort : choice.defaultEffort)
    }

    // MARK: - Entry points

    /// The toolbar button: pick an agent and get an analysis prompt ready, or show
    /// and hide a conversation already under way.
    func toolbarButtonPressed() {
        if started {
            isVisible.toggle()
        } else {
            prefillAfterPick = analysisPrompt()
            pickPurpose = .chat
            pickerShown = true
        }
    }

    /// "Free up space with AI" on the start screen: scan the whole disk and analyze
    /// it in one go. Pressing it is the request, so the analysis is sent unprompted.
    func freeUpSpacePressed() {
        if started {
            beginFreeUp()
        } else {
            pickPurpose = .freeUpSpace
            pickerShown = true
        }
    }

    private func beginFreeUp() {
        isVisible = true
        waitingForScan = true
        messages.append(Message(role: .info, text: L(.agentFreeUpScanning)))
        bump()
        AppState.shared.scan(URL(fileURLWithPath: "/"))
    }

    /// Called by the app when a scan ends, to send a waiting analysis.
    func scanFinished(completed: Bool) {
        guard waitingForScan else { return }
        waitingForScan = false
        if completed {
            send(analysisPrompt())
        } else {
            messages.append(Message(role: .info, text: L(.agentFreeUpCancelled)))
            bump()
        }
    }

    /// "Ask AI" on an item: a question about it, ready to send.
    func ask(about node: FileNode) {
        let detail = node.isDirectory
            ? "\(node.size.humanBytes), \(node.fileCount) \(L(.files))"
            : node.size.humanBytes
        let prompt = String(format: L(.agentPromptItem), Self.tilde(node.url.path), detail)
        if started {
            draft = prompt
            isVisible = true
        } else {
            prefillAfterPick = prompt
            pickPurpose = .chat
            pickerShown = true
        }
    }

    /// The picker's confirm button: start with the chosen agent, then open the chat
    /// with a prompt ready, or set off the scan-and-analyze run.
    func confirmPick() {
        pickerShown = false
        guard start() else { return }
        switch pickPurpose {
        case .chat:
            draft = prefillAfterPick
            prefillAfterPick = ""
            isVisible = true
        case .freeUpSpace:
            beginFreeUp()
        }
    }

    private func analysisPrompt() -> String {
        guard let root = AppState.shared.root, !AppState.shared.isScanning else {
            return L(.agentPromptAnalyzeNoScan)
        }
        return String(format: L(.agentPromptAnalyze), Self.tilde(root.url.path))
    }

    // MARK: - Conversation

    @discardableResult
    func start() -> Bool {
        if started { return true }
        guard let executable = kind.locate() else { return false }
        driver = kind.makeDriver(executable: executable) { [weak self] event in self?.handle(event) }
        started = true
        bump()
        return true
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard started, !text.isEmpty, !isRunning, let driver else { return }
        messages.append(Message(role: .user, text: text))
        messages.append(Message(role: .assistant))
        isRunning = true
        bump()
        do {
            try driver.send(text + context(), settings: settings)
        } catch {
            finishTurn(error: error.localizedDescription)
        }
    }

    /// Sends the composer's text.
    func sendDraft() {
        guard !isRunning else { return }
        let text = draft
        draft = ""
        send(text)
    }

    /// Stops the current answer; the next message continues the conversation.
    func stop() {
        guard isRunning else { return }
        driver?.stop()
        finishTurn(error: nil, notice: L(.agentStopped))
    }

    /// Ends the conversation and closes the sidebar; the toolbar button then offers
    /// the picker again.
    func newConversation() {
        driver?.shutdown()
        driver = nil
        started = false
        isRunning = false
        isVisible = false
        waitingForScan = false
        messages = []
        draft = ""
        bump()
    }

    func shutdown() { driver?.shutdown() }

    /// What the agent is doing right now, for the status line.
    var status: String? {
        guard isRunning, let answer = messages.last, answer.role == .assistant else { return nil }
        guard let last = answer.segments.last else { return L(.agentStatusStarting) }
        switch last.kind {
        case .thinking: return L(.agentStatusThinking)
        case .step: return last.state == .running ? last.text : L(.agentStatusThinking)
        case .text: return L(.agentStatusWriting)
        }
    }

    /// Where the user is in the app, appended to every prompt.
    private func context() -> String {
        let app = AppState.shared
        guard let root = app.root, !app.isScanning else { return "" }
        var parts = ["scan root: \(Self.tilde(root.url.path))"]
        if let focus = app.focus, focus.url.path != root.url.path {
            parts.append("viewing: \(Self.tilde(focus.url.path))")
        }
        if let selected = app.selected { parts.append("selected: \(Self.tilde(selected.url.path))") }
        return "\n\n(DiskLens — " + parts.joined(separator: " · ") + ")"
    }

    // MARK: - Events

    private func handle(_ event: AgentEvent) {
        // Stragglers from a stopped turn.
        guard isRunning else { return }
        switch event {
        case .thinking(let text):
            updateAnswer { m in
                if let i = m.segments.indices.last, m.segments[i].kind == .thinking, m.segments[i].ended == nil {
                    m.segments[i].text += text
                } else {
                    m.segments.append(Segment(kind: .thinking, text: text))
                }
            }
        case .text(let text):
            updateAnswer { m in
                Self.closeThinking(&m)
                if let i = m.segments.indices.last, m.segments[i].kind == .text {
                    m.segments[i].text += text
                } else if !text.isEmpty {
                    m.segments.append(Segment(kind: .text, text: text))
                }
            }
        case .paragraph:
            updateAnswer { m in
                guard let i = m.segments.indices.last, m.segments[i].kind == .text else { return }
                let t = m.segments[i].text
                if !t.isEmpty, !t.hasSuffix("\n\n") { m.segments[i].text += t.hasSuffix("\n") ? "\n" : "\n\n" }
            }
        case .toolStarted(let id, let name, let input):
            guard let label = Self.activityLabel(name, input) else { return }
            updateAnswer { m in
                Self.closeThinking(&m)
                var step = Segment(kind: .step, text: label)
                step.toolID = id
                m.segments.append(step)
            }
        case .toolFinished(let id, let ok, let summary):
            updateAnswer { m in
                guard let i = m.segments.lastIndex(where: { $0.toolID == id }) else { return }
                m.segments[i].state = ok ? .done : .failed
                m.segments[i].ended = Date()
                m.segments[i].detail = summary
            }
        case .trashed(let paths):
            paths.forEach { AppState.shared.removeNode(path: $0) }
        case .usage(let input, let output):
            updateAnswer { m in
                m.inputTokens += input
                m.outputTokens += output
            }
        case .finished(let error):
            finishTurn(error: error)
        }
    }

    private static func closeThinking(_ m: inout Message) {
        let now = Date()
        for i in m.segments.indices where m.segments[i].kind == .thinking && m.segments[i].ended == nil {
            m.segments[i].ended = now
        }
        // Models that don't share their reasoning still emit empty thinking; a blink
        // of it isn't worth a row.
        m.segments.removeAll { s in
            s.kind == .thinking && s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (s.ended ?? now).timeIntervalSince(s.started) < 1.5
        }
    }

    private func updateAnswer(_ change: (inout Message) -> Void) {
        guard let i = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        change(&messages[i])
        bump()
    }

    private func finishTurn(error: String?, notice: String? = nil) {
        isRunning = false
        if let i = messages.lastIndex(where: { $0.role == .assistant }) {
            Self.closeThinking(&messages[i])
            let now = Date()
            messages[i].ended = now
            for j in messages[i].segments.indices where messages[i].segments[j].ended == nil {
                messages[i].segments[j].ended = now
                // A step still open when the turn ends never reported back.
                if messages[i].segments[j].kind == .step { messages[i].segments[j].state = .failed }
            }
            // An answer that produced nothing at all is just noise.
            if messages[i].segments.isEmpty, i == messages.count - 1 { messages.remove(at: i) }
        }
        if let error {
            let detail = AgentSupport.readableError(error)
            messages.append(Message(role: .notice, text: L(.agentFailed) + (detail.isEmpty ? "" : " \(detail)")))
        }
        if let notice { messages.append(Message(role: .notice, text: notice)) }
        bump()
    }

    private func bump() { tick &+= 1 }

    // MARK: - Labels

    private static func activityLabel(_ tool: String, _ input: [String: Any]) -> String? {
        let path = (input["path"] as? String ?? input["file_path"] as? String).map(tilde)
        switch tool {
        case "disklens.current_scan": return L(.actCurrentScan)
        case "disklens.scan": return String(format: L(.actScan), path ?? "~")
        case "disklens.list": return String(format: L(.actList), path ?? "")
        case "disklens.largest_files": return String(format: L(.actLargest), path ?? "~")
        case "disklens.annotate":
            return String(format: L(.actAnnotate), (input["items"] as? [Any])?.count ?? 0)
        case "disklens.move_to_trash":
            return String(format: L(.actTrash), (input["paths"] as? [Any])?.count ?? 0)
        case "read": return String(format: L(.actRead), path ?? "")
        case "shell": return String(format: L(.actRun), input["command"] as? String ?? "")
        case "search": return String(format: L(.actFind), input["pattern"] as? String ?? "")
        case "web":
            return String(format: L(.actSearch), input["query"] as? String ?? input["url"] as? String ?? "")
        default: return nil
        }
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
