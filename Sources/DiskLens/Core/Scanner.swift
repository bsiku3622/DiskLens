import Foundation

/// Live progress emitted while a scan runs.
struct ScanProgress {
    var fileCount: Int = 0
    var byteCount: Int64 = 0
    /// Directories DiskLens couldn't read (usually a permissions block).
    var deniedCount: Int = 0
    /// Top-level item currently being measured, for the status line.
    var currentName: String = ""
}

enum ScanError: Error { case cancelled }

/// Identifies a real filesystem object by volume + inode, so the same directory
/// reached through more than one path (macOS firmlinks like `/Users` vs
/// `/System/Volumes/Data/Users`) is only ever counted once.
private struct InodeKey: Hashable {
    let dev: dev_t
    let ino: ino_t
}

/// Recursively measures on-disk usage of a directory tree.
///
/// Runs off the main actor. Cancellation is cooperative via `Task.isCancelled`.
/// As it walks, every file's bytes roll up into all of its ancestors, so the
/// tree's sizes are accurate at any instant — a throttled `onSnapshot` ships a
/// shallow copy to the UI a few times a second, growing the chart live even
/// while one huge top-level folder is still being measured.
struct Scanner {
    let root: URL
    /// Called periodically (not per file) so the UI can show progress cheaply.
    let onProgress: @Sendable (ScanProgress) -> Void
    /// A shallow, immutable copy of the tree so far — for the live chart.
    let onSnapshot: @Sendable (FileNode) -> Void
    /// The final, complete tree once the scan finishes.
    let onComplete: @Sendable (FileNode) -> Void

    /// How deep the live snapshots reach (the chart shows ~6 rings from the root).
    private static let snapshotDepth = 6
    private static let snapshotInterval: TimeInterval = 0.3
    /// Hard cap on nodes copied per snapshot so cost stays flat as the tree grows
    /// (otherwise a big scan's snapshots would swamp the scan thread and the UI).
    private static let snapshotBudget = 5000

    private static let sizeKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .nameKey
    ]

    func run() async throws {
        let rootName = root.path == "/" ? "Macintosh HD" : root.lastPathComponent
        let rootNode = FileNode(url: root, name: rootName, isDirectory: true, size: 0)

        var progress = ScanProgress()
        var visited = Set<InodeKey>()
        var lastEmit = Date.distantPast
        var lastSnap = Date.distantPast
        if let key = Self.inodeKey(root) { visited.insert(key) }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(Self.sizeKeys), options: [])) ?? []

        for entry in entries {
            if Task.isCancelled { throw ScanError.cancelled }
            progress.currentName = entry.lastPathComponent
            onProgress(progress)
            walk(url: entry, parent: rootNode, rootNode: rootNode,
                 progress: &progress, visited: &visited,
                 lastEmit: &lastEmit, lastSnap: &lastSnap)
        }

        if Task.isCancelled { throw ScanError.cancelled }
        progress.currentName = ""
        onProgress(progress)
        onComplete(rootNode)
    }

    private func walk(url: URL, parent: FileNode, rootNode: FileNode,
                      progress: inout ScanProgress, visited: inout Set<InodeKey>,
                      lastEmit: inout Date, lastSnap: inout Date) {
        if Task.isCancelled { return }

        let values = try? url.resourceValues(forKeys: Self.sizeKeys)
        let name = values?.name ?? url.lastPathComponent
        let isDir = values?.isDirectory ?? false
        let isSymlink = values?.isSymbolicLink ?? false

        // File (or symlink, which we never follow): measure and roll up.
        if isSymlink || !isDir {
            let bytes = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            let node = FileNode(url: url, name: name, isDirectory: false, size: bytes, fileCount: 1)
            parent.attachDuringScan(node)
            var ancestor: FileNode? = parent
            while let a = ancestor { a.accumulateDuringScan(bytes: bytes, files: 1); ancestor = a.parent }
            progress.fileCount += 1
            progress.byteCount += bytes
            maybeEmit(rootNode, &progress, &lastEmit, &lastSnap)
            return
        }

        // Directory: skip if already counted via another path (firmlink/hardlink).
        if let key = Self.inodeKey(url), !visited.insert(key).inserted { return }

        let node = FileNode(url: url, name: name, isDirectory: true, size: 0)
        parent.attachDuringScan(node)

        do {
            // Include hidden entries: caches, .git, dotfiles are often the biggest.
            let entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(Self.sizeKeys), options: [])
            for entry in entries {
                if Task.isCancelled { return }
                walk(url: entry, parent: node, rootNode: rootNode,
                     progress: &progress, visited: &visited,
                     lastEmit: &lastEmit, lastSnap: &lastSnap)
            }
        } catch {
            // Couldn't list the directory — almost always a permissions block.
            progress.deniedCount += 1
        }
        maybeEmit(rootNode, &progress, &lastEmit, &lastSnap)
    }

    private func maybeEmit(_ rootNode: FileNode, _ progress: inout ScanProgress,
                           _ lastEmit: inout Date, _ lastSnap: inout Date) {
        let now = Date()
        if now.timeIntervalSince(lastEmit) > 0.1 {
            lastEmit = now
            onProgress(progress)
        }
        if now.timeIntervalSince(lastSnap) > Self.snapshotInterval {
            lastSnap = now
            onSnapshot(Self.snapshot(rootNode, depth: Self.snapshotDepth, budget: Self.snapshotBudget))
        }
    }

    /// A directories-only copy for the live chart. Built **breadth-first** so shallow,
    /// large folders (the visible inner rings, e.g. every top-level of the disk) are
    /// always included; the node `budget` only truncates the deepest, smallest slices.
    /// Cost stays flat no matter how big the tree gets — the full, unbounded tree is
    /// delivered once via `onComplete`. Sizes already include every file so far.
    private static func snapshot(_ root: FileNode, depth: Int, budget: Int) -> FileNode {
        func shallowCopy(_ n: FileNode) -> FileNode {
            FileNode(url: n.url, name: n.name, isDirectory: n.isDirectory,
                     size: n.size, fileCount: n.fileCount)
        }
        let rootCopy = shallowCopy(root)
        var remaining = budget
        var queue: [(orig: FileNode, copy: FileNode, depth: Int)] = [(root, rootCopy, depth)]
        var head = 0
        while head < queue.count, remaining > 0 {
            let item = queue[head]; head += 1
            guard item.depth > 0 else { continue }
            let dirs = item.orig.children.filter { $0.isDirectory }.sorted { $0.size > $1.size }
            var copies: [FileNode] = []
            for child in dirs {
                if remaining <= 0 { break }
                remaining -= 1
                let childCopy = shallowCopy(child)
                copies.append(childCopy)
                queue.append((child, childCopy, item.depth - 1))
            }
            if !copies.isEmpty { item.copy.replaceChildrenForSnapshot(copies) }
        }
        return rootCopy
    }

    private static func inodeKey(_ url: URL) -> InodeKey? {
        url.withUnsafeFileSystemRepresentation { ptr -> InodeKey? in
            guard let ptr else { return nil }
            var st = stat()
            guard stat(ptr, &st) == 0 else { return nil }
            return InodeKey(dev: st.st_dev, ino: st.st_ino)
        }
    }
}
