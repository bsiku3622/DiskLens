import Foundation

/// A node in the scanned file tree. Reference type so the tree can be walked by
/// parent/child links and mutated in place when an item is trashed.
///
/// Built entirely on one background task, then handed to the main actor and only
/// read/mutated there — never touched concurrently — so `@unchecked Sendable` is safe.
final class FileNode: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool

    /// Total bytes on disk: own allocated size for files, sum of children for folders.
    private(set) var size: Int64
    private(set) var children: [FileNode]
    /// How many descendant files this node covers (for the folder summary).
    private(set) var fileCount: Int

    weak var parent: FileNode?

    init(url: URL, name: String, isDirectory: Bool, size: Int64,
         children: [FileNode] = [], fileCount: Int = 0) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
        self.fileCount = fileCount
        for child in children { child.parent = self }
    }

    /// Children sorted largest-first, dropping zero-byte entries for the chart.
    var sortedChildren: [FileNode] {
        children.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    var isRootLevel: Bool { parent == nil }

    /// Fraction of the parent's size this node occupies (0…1).
    var fractionOfParent: Double {
        guard let parent, parent.size > 0 else { return 1 }
        return Double(size) / Double(parent.size)
    }

    /// Path from the root down to this node, root first.
    var ancestry: [FileNode] {
        var chain: [FileNode] = []
        var cur: FileNode? = self
        while let node = cur {
            chain.append(node)
            cur = node.parent
        }
        return chain.reversed()
    }

    /// Attach a child while the background scan is building the tree.
    /// Only the scanner's single background thread calls this.
    func attachDuringScan(_ child: FileNode) {
        child.parent = self
        children.append(child)
    }

    /// Add a descendant file's bytes to this node during the scan (ancestor rollup).
    func accumulateDuringScan(bytes: Int64, files: Int) {
        size += bytes
        fileCount += files
    }

    /// Set children on a snapshot copy that is built parent-first (breadth-first).
    func replaceChildrenForSnapshot(_ newChildren: [FileNode]) {
        for child in newChildren { child.parent = self }
        children = newChildren
    }

    /// Remove a child (after it's been trashed) and roll the freed bytes up the tree.
    func removeChild(_ child: FileNode) {
        guard let idx = children.firstIndex(where: { $0.id == child.id }) else { return }
        children.remove(at: idx)
        let freed = child.size
        let freedFiles = child.isDirectory ? child.fileCount : 1
        var cur: FileNode? = self
        while let node = cur {
            node.size -= freed
            node.fileCount -= freedFiles
            cur = node.parent
        }
    }
}
