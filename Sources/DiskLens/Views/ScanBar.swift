import SwiftUI

/// Top toolbar: folder picker, scan status/progress, total, language toggle.
struct ScanBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var chat: AgentChat
    @AppStorage("appLanguage") private var langRaw = Lang.initial.rawValue
    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                state.chooseFolderAndScan()
            } label: {
                Label(L(.chooseFolder, lang), systemImage: "folder")
            }
            .disabled(state.isScanning)

            if state.scannedURL != nil {
                Button {
                    state.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L(.rescan, lang))
                .disabled(state.isScanning)
            }

            Divider().frame(height: 18)

            if state.isScanning {
                scanning
            } else if let root = state.root {
                summary(root)
            } else {
                Text(scannedName)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            Picker("", selection: $langRaw) {
                ForEach(Lang.allCases) { l in Text(l.label).tag(l.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .labelsHidden()

            // One entry point for the AI sidebar: picks an agent the first time,
            // then shows and hides the conversation.
            Button {
                chat.toolbarButtonPressed()
            } label: {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(chat.isVisible ? Color.purple : .primary)
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(chat.isVisible ? Color.purple.opacity(0.15) : .clear))
            }
            .buttonStyle(.borderless)
            .help(L(.agentButtonHelp, lang))
            .popover(isPresented: Binding(get: { chat.pickerShown && chat.pickPurpose == .chat },
                                          set: { if !$0 { chat.pickerShown = false } }),
                     arrowEdge: .bottom) {
                AgentPicker().environmentObject(chat)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var scanning: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(String(format: L(.scanningDetail, lang),
                        state.progress.fileCount, state.progress.byteCount.humanBytes))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1)
            if !state.progress.currentName.isEmpty {
                Text(String(format: L(.scanningItem, lang), state.progress.currentName))
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
            }
            Button(L(.cancel, lang)) { state.cancelScan() }
                .buttonStyle(.borderless)
        }
    }

    private func summary(_ root: FileNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            Text(root.name).font(.callout).bold()
                .lineLimit(1).truncationMode(.middle)
            Text("·").foregroundStyle(.tertiary)
            Text(root.size.humanBytes)
                .font(.callout).monospacedDigit().bold()
                .foregroundStyle(Color.accentColor)
            Text("(\(root.fileCount) \(L(.files, lang)))")
                .font(.caption).foregroundStyle(.secondary)
            if let volumes = state.volumes, volumes.scanRootIsVolumeRoot,
               volumes.containerUsedBytes > 0 {
                Text("·").foregroundStyle(.tertiary)
                HStack(spacing: 3) {
                    Text(String(format: L(.diskActual, lang),
                                volumes.containerUsedBytes.humanBytes))
                        .font(.caption).monospacedDigit()
                    Image(systemName: "info.circle").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .help(L(.cloneNote, lang))
            }
        }
    }

    private var scannedName: String {
        state.scannedURL?.lastPathComponent ?? ""
    }
}
