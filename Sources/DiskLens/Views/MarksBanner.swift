import SwiftUI

/// Banner for the items an agent marked, with a list that jumps to each one in the chart.
struct MarksBanner: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var annotations: AnnotationCenter
    @AppStorage("appLanguage") private var langRaw = Lang.initial.rawValue
    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    @Binding var dismissed: Bool
    @State private var listShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(headline).font(.callout).lineLimit(1)
                Spacer(minLength: 8)
                Button(listShown ? L(.deniedHideFolders, lang) : L(.marksShowList, lang)) {
                    listShown.toggle()
                }
                .buttonStyle(.borderless).controlSize(.small)
                Button(L(.marksClear, lang)) { annotations.clear() }
                    .buttonStyle(.borderless).controlSize(.small)
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L(.deniedDismiss, lang))
            }
            if listShown { list }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.purple.opacity(0.10))
    }

    private var headline: String {
        var text = String(format: L(.marksBanner, lang), annotations.source, annotations.items.count)
        if annotations.reclaimable > 0 {
            text += " · " + String(format: L(.marksReclaimable, lang), annotations.reclaimable.humanBytes)
        }
        return text
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(annotations.items, id: \.path) { item in
                    Button {
                        state.show(path: item.path)
                    } label: {
                        AnnotationRow(item: item, lang: lang)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 180)
    }
}

private struct AnnotationRow: View {
    let item: Annotation
    let lang: Lang

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VerdictChip(verdict: item.verdict, lang: lang)
            VStack(alignment: .leading, spacing: 1) {
                Text((item.path as NSString).lastPathComponent)
                    .font(.callout).lineLimit(1)
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(item.path)
                    .font(.caption2).monospaced().foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let bytes = item.reclaimBytes {
                Text(bytes.humanBytes)
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Small colored capsule naming a verdict, used in the banner and the contents list.
struct VerdictChip: View {
    let verdict: Verdict
    let lang: Lang

    var body: some View {
        Label(verdict.label(lang), systemImage: verdict.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(verdict.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(verdict.color.opacity(0.15)))
            .fixedSize()
    }
}
