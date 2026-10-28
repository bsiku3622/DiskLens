import Foundation

/// How an outside reviewer (Claude, via the MCP server or the storage-cleanup skill)
/// rates an item. The app only displays these; it never acts on them.
enum Verdict: String, Codable, CaseIterable, Sendable {
    /// Can go: caches, leftovers, things that regenerate.
    case safe
    /// The user should decide.
    case review
    /// Looks big but should stay.
    case keep
}

struct Annotation: Codable, Equatable, Sendable {
    var path: String
    var verdict: Verdict
    /// Why — shown as the row's subtitle and tooltip.
    var note: String
    /// Space a cleanup would actually free, when it differs from the item's size.
    var reclaimBytes: Int64?
}

struct AnnotationFile: Codable, Sendable {
    var version = 1
    var updatedAt: Date
    var source: String
    var items: [Annotation]
}

/// Reads and writes `~/Library/Application Support/DiskLens/annotations.json`.
/// The file is the hand-off point: anything may write it, and the app watches it.
enum AnnotationStore {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DiskLens/annotations.json")
    }

    static func load() -> AnnotationFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AnnotationFile.self, from: data)
    }

    /// Adds `items` (replacing marks on the same paths), or starts over when `replace`.
    @discardableResult
    static func write(_ items: [Annotation], replace: Bool, source: String) throws -> AnnotationFile {
        var byPath: [String: Annotation] = [:]
        var order: [String] = []
        if !replace, let existing = load() {
            for item in existing.items where byPath[item.path] == nil {
                byPath[item.path] = item
                order.append(item.path)
            }
        }
        for var item in items {
            item.path = normalize(item.path)
            if byPath[item.path] == nil { order.append(item.path) }
            byPath[item.path] = item
        }
        let file = AnnotationFile(updatedAt: Date(), source: source,
                                  items: order.compactMap { byPath[$0] })
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
        return file
    }

    /// Absolute, tilde-expanded, no trailing slash — the same shape as `FileNode.url.path`.
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
