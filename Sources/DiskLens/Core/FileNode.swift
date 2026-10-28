import Foundation

/// A node in the scanned file tree. Reference type so the tree can be walked by
/// parent/child links and mutated in place when an item is trashed.
///
/// Built by the scanner's worker threads under its tree lock (see `Scanner`), then
/// handed to the main actor and only read/mutated there — so `@unchecked Sendable`
/// is safe.
///
/// A whole-disk scan makes millions of these, so a node stores only its name: the
/// URL is derived from the parent chain on demand, and identity is the object itself.
final class FileNode: Identifiable, @unchecked Sendable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    let name: String
    let isDirectory: Bool
    /// Stands in for a volume the scan deliberately didn't walk into (see `VolumeMap`).
    /// Its size comes from the volume, not from summing children, so it can't be
    /// drilled into and must never be offered for deletion.
    let isSynthetic: Bool
    /// Set for roots, synthetic nodes and snapshot copies; scanned nodes derive theirs.
    private let explicitURL: URL?

    /// Total bytes on disk: own allocated size for files, sum of children for folders.
    private(set) var size: Int64
    private(set) var children: [FileNode]
    /// How many descendant files this node covers (for the folder summary).
    private(set) var fileCount: Int

    weak var parent: FileNode?

    init(url: URL, name: String, isDirectory: Bool, size: Int64,
         children: [FileNode] = [], fileCount: Int = 0, isSynthetic: Bool = false) {
        self.explicitURL = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
        self.fileCount = fileCount
        self.isSynthetic = isSynthetic
        for child in children { child.parent = self }
    }

    /// A scanned entry, located by its name under `parent`.
    init(name: String, isDirectory: Bool, size: Int64, fileCount: Int, parent: FileNode) {
        self.explicitURL = nil
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = []
        self.fileCount = fileCount
        self.isSynthetic = false
        self.parent = parent
    }

    var url: URL {
        if let explicitURL { return explicitURL }
        guard let parent else { return URL(fileURLWithPath: "/" + name) }
        return parent.url.appendingPathComponent(name, isDirectory: isDirectory)
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

    /// Attach a child while the scan is building the tree. Callers hold the
    /// scanner's tree lock.
    func attachDuringScan(_ child: FileNode) {
        child.parent = self
        children.append(child)
    }

    /// Install a directory's listing in one go. Callers hold the scanner's tree lock.
    func setChildrenDuringScan(_ newChildren: [FileNode]) {
        children = newChildren
    }

    /// Add descendant files' bytes to this node during the scan (ancestor rollup).
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
        guard let idx = children.firstIndex(where: { $0 === child }) else { return }
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
