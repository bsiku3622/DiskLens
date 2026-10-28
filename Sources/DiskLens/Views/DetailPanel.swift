import SwiftUI

/// Right-hand panel: breadcrumb + the focused folder's children, largest first.
struct DetailPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var annotations: AnnotationCenter
    @EnvironmentObject var chat: AgentChat
    @AppStorage("appLanguage") private var langRaw = Lang.initial.rawValue
    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    @State private var pendingTrash: FileNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
            Divider()
            header
            Divider()
            if let focus = state.focus, !focus.sortedChildren.isEmpty {
                List {
                    // Keyed by URL (not the per-snapshot node id) so a folder's row
                    // persists across live snapshots and its bar can animate in place.
                    ForEach(focus.sortedChildren, id: \.url) { child in
                        ChildRow(node: child,
                                 isHovered: state.hovered?.url == child.url,
                                 isSelected: state.selected?.url == child.url,
                                 // The synthetic volume group shares its parent's path,
                                 // so it would otherwise inherit every mark below it.
                                 annotation: child.isSynthetic ? nil : annotations.annotation(for: child.url.path),
                                 markedInside: child.isSynthetic ? 0 : annotations.markedInside(child.url.path),
                                 lang: lang,
                                 onTap: { state.drill(into: child) },
                                 onReveal: { state.reveal(child) },
                                 onAsk: chat.isRunning ? nil : { chat.ask(about: child) },
                                 onTrash: child.isSynthetic ? nil : { pendingTrash = child })
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            } else {
                emptyContents
            }
        }
        .frame(minWidth: 300)
        .confirmationDialog(
            L(.moveToTrashConfirm, lang),
            isPresented: Binding(get: { pendingTrash != nil },
                                 set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible,
            presenting: pendingTrash
        ) { node in
            Button(L(.deleteConfirm, lang), role: .destructive) {
                state.moveToTrash(node); pendingTrash = nil
            }
            Button(L(.deleteKeep, lang), role: .cancel) { pendingTrash = nil }
        } message: { node in
            Text(String(format: L(.moveToTrashMessage, lang), node.name))
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let root = state.root {
                    let chain = state.focus?.ancestry ?? [root]
                    ForEach(Array(chain.enumerated()), id: \.element.id) { idx, node in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button(node.name) { state.setFocus(node) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(node.id == state.focus?.id ? Color.primary : .secondary)
                            .fontWeight(node.id == state.focus?.id ? .semibold : .regular)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private var header: some View {
        HStack {
            Text(L(.largest, lang)).font(.subheadline).bold()
            Spacer()
            if let focus = state.focus {
                Text("\(focus.fileCount) \(L(.files, lang))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var emptyContents: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(L(.empty, lang)).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A single row in the contents list: color chip, name, proportion bar, size, actions.
private struct ChildRow: View {
    let node: FileNode
    let isHovered: Bool
    let isSelected: Bool
    /// The agent's verdict on this item, if any.
    let annotation: Annotation?
    /// Marked items somewhere inside this folder.
    let markedInside: Int
    let lang: Lang
    let onTap: () -> Void
    let onReveal: () -> Void
    /// nil while the agent is already answering.
    let onAsk: (() -> Void)?
    /// nil for a synthetic volume node — there's no real path to move to the Trash.
    let onTrash: (() -> Void)?

    @State private var rowHover = false

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: Theme.icon(for: node))
                    .font(.body)
                    .foregroundStyle(Theme.tint(for: node))
                    .frame(width: 20)
                Text(node.name)
                    .font(.callout)
                    .lineLimit(1).truncationMode(.middle)
                if let annotation {
                    VerdictChip(verdict: annotation.verdict, lang: lang)
                        .help(annotation.note)
                } else if markedInside > 0 {
                    Image(systemName: "sparkles")
                        .font(.caption2).foregroundStyle(.purple)
                        .help(String(format: L(.marksInside, lang), markedInside))
                }
                Spacer(minLength: 6)
                Text(node.size.humanBytes)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ProportionBar(fraction: node.fractionOfParent, tint: Theme.tint(for: node))
                Text(percentText)
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
            }
            if let note = annotation?.note, !note.isEmpty {
                Text(note)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(background)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { rowHover = $0 }
        .overlay(alignment: .trailing) {
            if rowHover {
                HStack(spacing: 4) {
                    if let onAsk {
                        IconButton(system: "sparkles", help: L(.agentAsk, lang), tint: .purple, action: onAsk)
                    }
                    IconButton(system: "magnifyingglass", help: L(.revealInFinder, lang), action: onReveal)
                    if let onTrash {
                        IconButton(system: "trash", help: L(.moveToTrash, lang), tint: .red, action: onTrash)
                    }
                }
                .padding(.trailing, 6)
                .transition(.opacity)
            }
        }
        .contextMenu {
            if let onAsk {
                Button(L(.agentAsk, lang), systemImage: "sparkles", action: onAsk)
            }
            Button(L(.revealInFinder, lang), systemImage: "magnifyingglass", action: onReveal)
            if let onTrash {
                Divider()
                Button(L(.moveToTrash, lang), systemImage: "trash", role: .destructive, action: onTrash)
            }
        }
    }

    private var percentText: String {
        let pct = node.fractionOfParent * 100
        return pct >= 9.95 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovered || rowHover { return Color.primary.opacity(0.06) }
        return .clear
    }
}

private struct ProportionBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: max(2, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                    // Tween between the ~20 fps snapshots so the bar reads as 60 fps.
                    .animation(.linear(duration: 0.05), value: fraction)
            }
        }
        .frame(height: 5)
    }
}

private struct IconButton: View {
    let system: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.caption)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(help)
    }
}
