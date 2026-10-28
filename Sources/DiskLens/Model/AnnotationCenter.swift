import SwiftUI

/// The app's view of `annotations.json`: an agent's verdicts on items, shown as
/// badges and outlines. Polls the file so marks written while the app is open
/// appear within a couple of seconds.
@MainActor
final class AnnotationCenter: ObservableObject {
    static let shared = AnnotationCenter()

    @Published private(set) var items: [Annotation] = []
    @Published private(set) var updatedAt: Date?
    /// Who wrote the marks ("Claude", "Codex"), for the banner.
    @Published private(set) var source = "AI"
    private var byPath: [String: Annotation] = [:]
    /// Every folder that contains a marked item, so the chart can trace the way in.
    private var ancestors: [String: Int] = [:]
    private var fileStamp: Date?
    private var timer: Timer?
    /// Marks from an earlier session are stale: the disk has moved on since. Ones
    /// written just before launch still count — an agent annotates, then opens the app.
    private let oldestShown = Date().addingTimeInterval(-120)

    private init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AnnotationCenter.shared.reloadIfChanged() }
        }
    }

    func annotation(for path: String) -> Annotation? { byPath[path] }

    /// How many marked items sit somewhere inside `path`.
    func markedInside(_ path: String) -> Int { ancestors[path] ?? 0 }

    /// Space the "safe" marks would free.
    var reclaimable: Int64 {
        items.filter { $0.verdict == .safe }.reduce(0) { $0 + ($1.reclaimBytes ?? 0) }
    }

    func clear() {
        _ = try? AnnotationStore.write([], replace: true, source: "DiskLens")
        reload()
    }

    private func reloadIfChanged() {
        let stamp = (try? AnnotationStore.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if stamp != fileStamp { reload() }
    }

    private func reload() {
        fileStamp = (try? AnnotationStore.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let file = AnnotationStore.load().flatMap { $0.updatedAt >= oldestShown ? $0 : nil }
        items = file?.items ?? []
        updatedAt = file?.updatedAt
        source = file?.source ?? "AI"
        byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var counts: [String: Int] = [:]
        for item in items {
            var dir = (item.path as NSString).deletingLastPathComponent
            while !dir.isEmpty {
                counts[dir, default: 0] += 1
                if dir == "/" { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        ancestors = counts
    }
}

extension Verdict {
    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .keep: return .blue
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .review: return "questionmark.circle.fill"
        case .keep: return "lock.circle.fill"
        }
    }

    func label(_ lang: Lang) -> String {
        switch self {
        case .safe: return L(.verdictSafe, lang)
        case .review: return L(.verdictReview, lang)
        case .keep: return L(.verdictKeep, lang)
        }
    }
}
