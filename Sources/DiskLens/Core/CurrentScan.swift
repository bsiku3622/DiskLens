import Foundation

/// The app's latest finished scan, saved for the MCP server so Claude in the sidebar
/// reads the same tree the user is looking at instead of scanning again.
enum CurrentScan {
    /// Finer than the export default: the sidebar drills into whatever the user points at.
    static let minSize: Int64 = 1_000_000

    static var fileURL: URL {
        AnnotationStore.fileURL.deletingLastPathComponent().appendingPathComponent("current-scan.json")
    }

    static func save(_ report: ScanReport) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try HeadlessCommand.encoder.encode(report).write(to: fileURL, options: .atomic)
        } catch {
            // The sidebar falls back to scanning on its own; nothing to surface.
        }
    }

    static func load() -> ScanReport? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanReport.self, from: data)
    }

    static var modified: Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
