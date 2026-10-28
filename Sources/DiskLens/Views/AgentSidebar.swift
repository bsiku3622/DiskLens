import SwiftUI

/// Right-hand sidebar for talking with a coding agent about the scan.
struct AgentSidebar: View {
    @EnvironmentObject var chat: AgentChat
    @AppStorage("appLanguage") private var langRaw = Lang.initial.rawValue
    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if chat.waitingForScan {
                ScanStatusLine(lang: lang)
                Divider()
            } else if let status = chat.status, let started = chat.messages.last?.started {
                StatusLine(text: status, since: started, lang: lang)
                Divider()
            }
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: chat.kind.symbol).foregroundStyle(.purple)
            Text(chat.kind.displayName).font(.subheadline).bold()
            modelMenu
            Spacer()
            Button {
                chat.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help(L(.agentNewChat, lang))
            Button {
                chat.isVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L(.agentClose, lang))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Model and reasoning level; a change applies from the next message.
    private var modelMenu: some View {
        Menu {
            Section(L(.agentModel, lang)) {
                ForEach(chat.kind.models()) { model in
                    Button {
                        chat.selectModel(model)
                    } label: {
                        if model.id == chat.settings.model {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            }
            Section(L(.agentEffort, lang)) {
                ForEach(chat.currentModel?.efforts ?? [chat.settings.effort], id: \.self) { effort in
                    Button {
                        chat.settings.effort = effort
                    } label: {
                        if effort == chat.settings.effort {
                            Label(effortName(effort, lang), systemImage: "checkmark")
                        } else {
                            Text(effortName(effort, lang))
                        }
                    }
                }
            }
        } label: {
            Text("\(chat.kind.modelName(chat.settings.model)) · \(effortName(chat.settings.effort, lang))")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(chat.isRunning)
        .help(L(.agentModelHelp, lang))
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.messages.isEmpty {
                        Text(L(.agentEmptyHint, lang))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(chat.messages) { message in
                        MessageView(message: message, lang: lang,
                                    isLive: chat.isRunning && message.id == chat.messages.last?.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: chat.tick) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L(.agentPlaceholder, lang), text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit { chat.sendDraft() }
            if chat.isRunning {
                Button {
                    chat.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .help(L(.agentStop, lang))
            } else {
                let empty = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button {
                    chat.sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(empty ? Color.secondary : .purple)
                .disabled(empty)
                .help(L(.agentSend, lang))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .onAppear { inputFocused = true }
    }
}

/// "Looking at ~/Library · 12s" with a spinner, while a turn runs.
private struct StatusLine: View {
    let text: String
    let since: Date
    let lang: Lang

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(text)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(durationText(context.date.timeIntervalSince(since), lang))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.purple.opacity(0.06))
        }
    }
}

/// The scan that "Free up space with AI" waits on. Observes the scan on its own, so
/// its 60 fps progress doesn't redraw the whole transcript.
private struct ScanStatusLine: View {
    @EnvironmentObject var state: AppState
    let lang: Lang
    @State private var since = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(String(format: L(.agentScanStatus, lang),
                            state.progress.fileCount.formatted(), state.progress.byteCount.humanBytes))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(durationText(context.date.timeIntervalSince(since), lang))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.purple.opacity(0.06))
        }
    }
}

private struct MessageView: View {
    let message: AgentChat.Message
    let lang: Lang
    let isLive: Bool

    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.15)))
            }
        case .notice:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .info:
            Label(message.text, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pieces) { piece in
                    switch piece {
                    case .single(let segment):
                        switch segment.kind {
                        case .thinking: ThinkingBlock(segment: segment, lang: lang)
                        case .step: StepRow(segment: segment, lang: lang)
                        case .text: ChatMarkdown(text: segment.text)
                        }
                    case .steps(let steps):
                        StepGroup(steps: steps, lang: lang)
                    }
                }
                if !isLive, let ended = message.ended { footer(ended) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A run of tool calls between bits of thinking or text.
    private enum Piece: Identifiable {
        case single(AgentChat.Segment)
        case steps([AgentChat.Segment])

        var id: UUID {
            switch self {
            case .single(let s): return s.id
            case .steps(let steps): return steps[0].id
            }
        }
    }

    /// Long runs of steps fold into one row so a big analysis (dozens of calls) stays
    /// readable; short runs stay as they are.
    private var pieces: [Piece] {
        var out: [Piece] = []
        var run: [AgentChat.Segment] = []
        func flush() {
            if run.count > 3 { out.append(.steps(run)) } else { out += run.map(Piece.single) }
            run = []
        }
        for segment in message.segments {
            if segment.kind == .step {
                run.append(segment)
            } else {
                flush()
                out.append(.single(segment))
            }
        }
        flush()
        return out
    }

    private func footer(_ ended: Date) -> some View {
        var parts = [durationText(ended.timeIntervalSince(message.started), lang)]
        if message.inputTokens + message.outputTokens > 0 {
            parts.append(String(format: L(.agentTokens, lang),
                                tokenText(message.inputTokens), tokenText(message.outputTokens)))
        }
        return HStack(spacing: 8) {
            Text(parts.joined(separator: " · "))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
            if !message.answer.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.answer, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? L(.agentCopied, lang) : L(.agentCopy, lang),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Reasoning, live while it streams, then folded to "Thought for 8s ▸".
private struct ThinkingBlock: View {
    let segment: AgentChat.Segment
    let lang: Lang

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if segment.ended != nil { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").font(.caption)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(title(now: context.date)).font(.caption)
                    }
                    if segment.ended != nil, !segment.text.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if segment.ended == nil, !segment.text.isEmpty {
                // Live: the last few lines, faded.
                Text(inlineMarkdown(tail))
                    .font(.caption).italic().foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.purple.opacity(0.3)).frame(width: 2) }
            } else if expanded {
                Text(inlineMarkdown(segment.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.purple.opacity(0.3)).frame(width: 2) }
            }
        }
    }

    private func title(now: Date) -> String {
        let seconds = (segment.ended ?? now).timeIntervalSince(segment.started)
        if segment.ended == nil { return L(.agentStatusThinking, lang) + " " + durationText(seconds, lang) }
        // Codex often delivers its reasoning summary only when it's done, so there's
        // no real duration to report.
        return seconds < 1 ? L(.agentReasoning, lang)
                           : String(format: L(.agentThoughtFor, lang), durationText(seconds, lang))
    }

    private var tail: String {
        segment.text.split(separator: "\n").suffix(3).joined(separator: "\n")
    }
}

/// "12 steps · 1 failed · 34s ▸", with the step in progress shown beneath while it runs.
private struct StepGroup: View {
    let steps: [AgentChat.Segment]
    let lang: Lang

    @State private var expanded = false

    var body: some View {
        let running = steps.last { $0.state == .running }
        let failed = steps.filter { $0.state == .failed }.count
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Group {
                        if running != nil {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "list.bullet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 14)
                    Text(String(format: L(.agentSteps, lang), steps.count)
                         + (failed > 0 ? " · " + String(format: L(.agentStepsFailed, lang), failed) : ""))
                        .font(.caption)
                    Spacer(minLength: 6)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText((steps.last?.ended ?? context.date).timeIntervalSince(steps[0].started), lang))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(steps) { StepRow(segment: $0, lang: lang).padding(.leading, 12) }
            } else if let running {
                StepRow(segment: running, lang: lang).padding(.leading, 12)
            }
        }
    }
}

/// One tool call: spinner, check or cross, what it did, how long, and its output.
private struct StepRow: View {
    let segment: AgentChat.Segment
    let lang: Lang

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if segment.detail != nil { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    icon.frame(width: 14)
                    Text(segment.text)
                        .font(.caption)
                        .foregroundStyle(segment.state == .failed ? Color.red : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText((segment.ended ?? context.date).timeIntervalSince(segment.started), lang))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    if segment.detail != nil {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let detail = segment.detail {
                Text(detail)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch segment.state {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        }
    }
}

/// The toolbar button's popover: choose the agent and its model, then confirm.
struct AgentPicker: View {
    @EnvironmentObject var chat: AgentChat
    @AppStorage("appLanguage") private var langRaw = Lang.initial.rawValue
    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.agentPickTitle, lang)).font(.headline)
            Text(L(chat.pickPurpose == .freeUpSpace ? .agentFreeUpHint : .agentPickHint, lang))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(AgentKind.allCases) { kind in row(kind) }
            }
            if chat.isInstalled(chat.kind) { modelControls }
            HStack {
                Spacer()
                Button(L(.cancel, lang)) { chat.pickerShown = false }
                    .keyboardShortcut(.cancelAction)
                Button(L(.agentConfirm, lang)) { chat.confirmPick() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(!chat.isInstalled(chat.kind))
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var modelControls: some View {
        let models = chat.kind.models()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L(.agentModel, lang)).font(.callout).frame(width: 74, alignment: .leading)
                Picker("", selection: Binding(
                    get: { chat.settings.model },
                    set: { id in if let m = models.first(where: { $0.id == id }) { chat.selectModel(m) } }
                )) {
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
            if let note = chat.currentModel?.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.tertiary).padding(.leading, 78)
            }
            HStack {
                Text(L(.agentEffort, lang)).font(.callout).frame(width: 74, alignment: .leading)
                Picker("", selection: $chat.settings.effort) {
                    ForEach(chat.currentModel?.efforts ?? [chat.settings.effort], id: \.self) {
                        Text(effortName($0, lang)).tag($0)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private func row(_ kind: AgentKind) -> some View {
        let installed = chat.isInstalled(kind)
        let chosen = chat.kind == kind
        return Button {
            chat.kind = kind
        } label: {
            HStack(spacing: 10) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen ? Color.purple : .secondary)
                Image(systemName: kind.symbol).frame(width: 18)
                Text(kind.displayName).font(.callout)
                Spacer()
                if !installed {
                    Text(L(.agentNotInstalled, lang)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8)
                .stroke(chosen ? Color.purple.opacity(0.6) : Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(!installed)
        .help(installed ? kind.displayName : String(format: L(.agentNotInstalledHelp, lang), kind.displayName))
    }
}

/// "8s", "1m 5s" / "8초", "1분 5초".
private func durationText(_ seconds: TimeInterval, _ lang: Lang) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return lang == .ko ? "\(s)초" : "\(s)s" }
    return lang == .ko ? "\(s / 60)분 \(s % 60)초" : "\(s / 60)m \(s % 60)s"
}

/// Reasoning summaries come with **bold** titles and `code`.
private func inlineMarkdown(_ s: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
}

/// 62370 → "62.4k".
private func tokenText(_ n: Int) -> String {
    n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
}

/// Small markdown renderer for chat replies: headings, lists, code blocks and inline
/// styling. `Text` alone only understands inline markdown.
struct ChatMarkdown: View {
    let text: String

    private enum Block {
        case paragraph(String)
        case heading(String)
        case bullet(String, indent: Int, marker: String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let s):
            inline(s).font(.callout).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            inline(s).font(.callout.weight(.semibold)).padding(.top, 2)
        case .bullet(let s, let indent, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.callout).foregroundStyle(.secondary)
                inline(s).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .code(let s):
            Text(s)
                .font(.caption.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: s, options: options) { return Text(attributed) }
        return Text(s)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for raw in text.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    out.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }

            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indent = (raw.prefix(while: { $0 == " " }).count) / 2
            if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("#") {
                flush()
                out.append(.heading(String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                out.append(.bullet(String(trimmed.dropFirst(2)), indent: indent, marker: "•"))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber),
                      !trimmed[..<dot].isEmpty, trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                out.append(.bullet(String(trimmed[trimmed.index(dot, offsetBy: 2)...]), indent: indent,
                                   marker: String(trimmed[...dot])))
            } else if trimmed.hasPrefix("|") {
                flush()
                out.append(.code(trimmed))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = code { out.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return out
    }
}
