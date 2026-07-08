import Foundation

/// Moves items to the Trash (recoverable), never a hard delete.
enum TrashService {
    /// Returns the item's new location inside the Trash on success.
    @discardableResult
    static func moveToTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}
