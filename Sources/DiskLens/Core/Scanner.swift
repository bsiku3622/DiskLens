import Foundation

/// Live progress emitted while a scan runs.
struct ScanProgress: Sendable {
    var fileCount: Int = 0
    var byteCount: Int64 = 0
    /// Directories DiskLens couldn't list that Full Disk Access would actually
    /// unlock — the ones the user owns (Desktop, Documents, Mail and friends).
    var deniedFixable: Int = 0
    /// Directories owned by root with no world access. No permission the app can
    /// request opens these; only running as root would. Kept separate so the banner
    /// never promises a fix that can't work.
    var deniedProtected: Int = 0
    /// A capped sample of the blocked paths, so the banner can show which ones.
    var deniedPaths: [String] = []
    /// Top-level item currently being measured, for the status line.
    var currentName: String = ""

    var deniedCount: Int { deniedFixable + deniedProtected }
}

enum ScanError: Error { case cancelled }

/// Identifies a real filesystem object by volume + inode, so the same directory
/// reached through more than one path (macOS firmlinks like `/Users` vs
/// `/System/Volumes/Data/Users`) is only ever counted once.
private struct InodeKey: Hashable {
    let dev: dev_t
    let ino: ino_t
}

/// Mutable bookkeeping for one run. A class so the recursive walk can share it
/// without threading half a dozen `inout` parameters; only the scan task touches it.
private final class WalkState {
    var progress = ScanProgress()
    var visitedDirs = Set<InodeKey>()
    /// Inodes of files with more than one link, so a hardlinked file's bytes are
    /// counted once no matter how many paths reach it.
    var visitedLinkedFiles = Set<InodeKey>()
    var lastEmit = Date.distantPast
    var lastSnap = Date.distantPast
    /// st_dev of the volume the scan started on; anything else is a mount boundary.
    let rootDev: dev_t?

    init(rootDev: dev_t?) { self.rootDev = rootDev }
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
    /// Mount table as of scan start: decides what happens at a volume boundary.
    let volumes: VolumeMap
    /// Called periodically (not per file) so the UI can show progress cheaply.
    let onProgress: @Sendable (ScanProgress) -> Void
    /// A shallow, immutable copy of the tree so far — for the live chart.
    let onSnapshot: @Sendable (FileNode) -> Void
    /// The final, complete tree once the scan finishes.
    let onComplete: @Sendable (FileNode) -> Void

    /// How deep the live snapshots reach (the chart shows ~6 rings from the root).
    private static let snapshotDepth = 6
    /// The counter refreshes at 60 fps (cheap). Tree snapshots — which rebuild the
    /// chart and roll up thousands of nodes — refresh at 20 fps to avoid starving
    /// the scan; the detail bars animate between snapshots so they still read as 60 fps.
    private static let progressInterval: TimeInterval = 1.0 / 60
    private static let snapshotInterval: TimeInterval = 1.0 / 20
    /// Hard cap on nodes copied per snapshot so cost stays flat as the tree grows
    /// (otherwise a big scan's snapshots would swamp the scan thread and the UI).
    private static let snapshotBudget = 5000
    /// How many blocked paths to remember for the banner's list.
    private static let deniedPathSampleLimit = 200

    /// macOS firmlinks expose the data volume's contents at two paths — `/Users` and
    /// `/System/Volumes/Data/Users` are one directory. The walk keeps whichever it
    /// reaches first, so descending through `/System` would bury the home folder four
    /// levels deep. Visiting anything that leads to the data volume last keeps
    /// `/Users`, `/Applications` and `/private` on the top ring where they belong.
    private static let dataVolumeMount = "/System/Volumes/Data"

    private static let sizeKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .nameKey, .linkCountKey
    ]

    func run() async throws {
        let rootName = root.path == "/" ? "Macintosh HD" : root.lastPathComponent
        let rootNode = FileNode(url: root, name: rootName, isDirectory: true, size: 0)

        let state = WalkState(rootDev: Self.deviceID(root))

        // Volumes mounted under the scan root are known from the mount table, so they
        // go in before the walk starts and show up in the very first live snapshot.
        attachSiblingVolumes(to: rootNode, state: state)

        if let key = Self.inodeKey(root) { state.visitedDirs.insert(key) }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(Self.sizeKeys), options: [])) ?? []

        for entry in Self.dataVolumeLast(entries, in: root.path) {
            if Task.isCancelled { throw ScanError.cancelled }
            state.progress.currentName = entry.lastPathComponent
            onProgress(state.progress)
            walk(url: entry, parent: rootNode, rootNode: rootNode, state: state)
        }

        if Task.isCancelled { throw ScanError.cancelled }
        state.progress.currentName = ""
        onProgress(state.progress)
        onComplete(rootNode)
    }

    /// Adds one synthetic node per sibling volume, grouped under a single entry.
    ///
    /// These volumes (Preboot, VM, Update…) hold real bytes on the same physical disk,
    /// but they're system-managed and largely unreadable, and walking them double-counts:
    /// `/System/Volumes/Update/mnt1` is the sealed system snapshot, a byte-for-byte
    /// mirror of `/`. Sizing them from the volume itself is both accurate and cheap.
    private func attachSiblingVolumes(to rootNode: FileNode, state: WalkState) {
        guard !volumes.siblings.isEmpty else { return }
        // The group is a label, not a place; point it at the scan root so revealing it
        // lands somewhere real whatever the siblings turn out to be.
        let group = FileNode(url: root, name: L(.systemReserved), isDirectory: true,
                             size: 0, isSynthetic: true)
        for sibling in volumes.siblings {
            let node = FileNode(url: URL(fileURLWithPath: sibling.path), name: sibling.name,
                                isDirectory: true, size: sibling.spaceUsed, isSynthetic: true)
            group.attachDuringScan(node)
            group.accumulateDuringScan(bytes: sibling.spaceUsed, files: 0)
        }
        rootNode.attachDuringScan(group)
        rootNode.accumulateDuringScan(bytes: group.size, files: 0)
        state.progress.byteCount += group.size
    }

    private func walk(url: URL, parent: FileNode, rootNode: FileNode, state: WalkState) {
        if Task.isCancelled { return }

        let values = try? url.resourceValues(forKeys: Self.sizeKeys)
        let name = values?.name ?? url.lastPathComponent
        let isDir = values?.isDirectory ?? false
        let isSymlink = values?.isSymbolicLink ?? false

        // File (or symlink, which we never follow): measure and roll up.
        if isSymlink || !isDir {
            var bytes = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            // Hardlinks are one file wearing several names; charge the bytes once.
            // Only files with more than one link can collide, so only they pay for the stat.
            if (values?.linkCount ?? 1) > 1, let key = Self.inodeKey(url),
               !state.visitedLinkedFiles.insert(key).inserted {
                bytes = 0
            }
            let node = FileNode(url: url, name: name, isDirectory: false, size: bytes, fileCount: 1)
            parent.attachDuringScan(node)
            var ancestor: FileNode? = parent
            while let a = ancestor { a.accumulateDuringScan(bytes: bytes, files: 1); ancestor = a.parent }
            state.progress.fileCount += 1
            state.progress.byteCount += bytes
            maybeEmit(rootNode, state)
            return
        }

        if let key = Self.inodeKey(url) {
            // A different st_dev means another filesystem. Whatever belongs in the
            // total was already added as a sibling node, and everything else — a
            // second mount of a volume we counted, a foreign disk, devfs, autofs —
            // must not be walked. An APFS volume group shares one st_dev, so the data
            // volume isn't a boundary and is still reached through its firmlinks.
            if let rootDev = state.rootDev, key.dev != rootDev { return }
            // Same inode seen before: a firmlink pointing at a directory we counted.
            if !state.visitedDirs.insert(key).inserted { return }
        }

        let node = FileNode(url: url, name: name, isDirectory: true, size: 0)
        parent.attachDuringScan(node)

        do {
            // Include hidden entries: caches, .git, dotfiles are often the biggest.
            let entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(Self.sizeKeys), options: [])
            for entry in Self.dataVolumeLast(entries, in: url.path) {
                if Task.isCancelled { return }
                walk(url: entry, parent: node, rootNode: rootNode, state: state)
            }
        } catch {
            recordDenied(url, state: state)
        }
        maybeEmit(rootNode, state)
    }

    /// Notes a directory the scan couldn't list, split by whether the user can fix it.
    ///
    /// Full Disk Access is a TCC grant over the user's *own* protected data. It does
    /// nothing for a root-owned directory with no world permissions — `/private/var/db/*`,
    /// `/System/Library/Templates` and the like stay closed however many toggles are on.
    private func recordDenied(_ url: URL, state: WalkState) {
        var st = stat()
        let statOK = url.withUnsafeFileSystemRepresentation { ptr -> Bool in
            guard let ptr else { return false }
            return stat(ptr, &st) == 0
        }
        // If even stat fails we can't attribute it — count it as protected rather than
        // claim Full Disk Access would help.
        if statOK && st.st_uid == getuid() {
            state.progress.deniedFixable += 1
        } else {
            state.progress.deniedProtected += 1
        }
        if state.progress.deniedPaths.count < Self.deniedPathSampleLimit {
            state.progress.deniedPaths.append(url.path)
        }
    }

    /// Reorders one directory listing so entries leading to the data volume go last.
    /// Only directories that sit on the path to that mount can hold such an entry, so
    /// everywhere else — which is nearly every directory on the disk — returns as-is
    /// without allocating.
    private static func dataVolumeLast(_ entries: [URL], in directory: String) -> [URL] {
        guard directory == "/" || dataVolumeMount.hasPrefix(directory + "/") else { return entries }
        var head: [URL] = [], tail: [URL] = []
        for entry in entries {
            let path = entry.path
            if path == dataVolumeMount || dataVolumeMount.hasPrefix(path + "/") {
                tail.append(entry)
            } else {
                head.append(entry)
            }
        }
        return tail.isEmpty ? entries : head + tail
    }

    private func maybeEmit(_ rootNode: FileNode, _ state: WalkState) {
        let now = Date()
        if now.timeIntervalSince(state.lastEmit) > Self.progressInterval {
            state.lastEmit = now
            onProgress(state.progress)
        }
        if now.timeIntervalSince(state.lastSnap) > Self.snapshotInterval {
            state.lastSnap = now
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
                     size: n.size, fileCount: n.fileCount, isSynthetic: n.isSynthetic)
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

    private static func deviceID(_ url: URL) -> dev_t? {
        inodeKey(url)?.dev
    }
}
