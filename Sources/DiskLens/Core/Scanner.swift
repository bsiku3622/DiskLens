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
    let ino: UInt64
}

/// One data stream on disk, however many names reach it: the APFS clone ID where the
/// volume has one, otherwise the inode. Hard links of a file share its clone ID too.
private struct StreamKey: Hashable {
    let dev: dev_t
    let id: UInt64
}

/// The file currently carrying a shared stream's bytes.
private struct StreamOwner {
    let node: FileNode
    let path: String
    let bytes: Int64
}

/// A directory waiting to be listed: its node and its real path.
private struct PendingDir {
    let node: FileNode
    let path: String
}

/// Shared bookkeeping for one run.
///
/// Two locks: `tree` guards the tree, the visited sets and the progress counters;
/// `queue` guards the work queue and wakes idle workers. A worker takes `tree` once
/// per directory, not per file, so contention stays low.
private final class WalkState: @unchecked Sendable {
    let tree = NSLock()
    var progress = ScanProgress()
    var visitedDirs = Set<InodeKey>()
    /// Streams with more than one name (hard links, APFS clones), so their bytes are
    /// counted once no matter how many paths reach them.
    var streamOwners: [StreamKey: StreamOwner] = [:]

    let queue = NSCondition()
    var pending: [PendingDir] = []
    /// The data volume's mount, held back until everything else is done (see `run`).
    var deferred: [PendingDir] = []
    var active = 0
    var cancelled = false
    var finished = false

    /// st_dev of the volume the scan started on; anything else is a mount boundary.
    let rootDev: dev_t?

    init(rootDev: dev_t?) { self.rootDev = rootDev }

    /// Stops the workers at their next directory.
    func cancel() {
        queue.lock()
        cancelled = true
        queue.broadcast()
        queue.unlock()
    }

    /// Marks the run over for the monitor; returns whether it was cancelled.
    func finish() -> Bool {
        queue.lock()
        defer { queue.unlock() }
        finished = true
        return cancelled
    }

    func finalProgress() -> ScanProgress {
        tree.lock()
        defer { tree.unlock() }
        progress.currentName = ""
        return progress
    }
}

/// Measures on-disk usage of a directory tree.
///
/// Directories are listed in parallel by a pool of worker threads, each reading a
/// whole directory per `getattrlistbulk(2)` call — name, type, inode, link count and
/// allocated size in one go, instead of a `stat` per file. Files' bytes roll up into
/// every ancestor as each directory finishes, so sizes are right at any instant; a
/// monitor thread ships progress and throttled shallow snapshots for the live chart.
/// Measured on 3.5M files with the metadata cached: 5–8 min with the old FileManager
/// walk, about a minute or less here. A cold cache still takes minutes: that's disk I/O.
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
    /// Headless runs have no chart to feed, so they skip building snapshots.
    var liveSnapshots = true

    /// How deep the live snapshots reach (the chart shows ~6 rings from the root).
    private static let snapshotDepth = 6
    /// The counter refreshes at 60 fps (cheap). Tree snapshots — which rebuild the
    /// chart and roll up thousands of nodes — refresh at 20 fps; the detail bars
    /// animate between snapshots so they still read as 60 fps.
    private static let progressInterval: TimeInterval = 1.0 / 60
    private static let snapshotInterval: TimeInterval = 1.0 / 20
    /// Hard cap on nodes copied per snapshot so cost stays flat as the tree grows.
    private static let snapshotBudget = 5000
    /// How many blocked paths to remember for the banner's list.
    private static let deniedPathSampleLimit = 200
    /// Parallel listings keep the SSD's queue full; past ~8 the gain flattens while
    /// kernel time keeps climbing.
    private static var workerCount: Int { max(4, min(ProcessInfo.processInfo.activeProcessorCount, 12)) }
    private static let bufferSize = 256 * 1024

    /// macOS firmlinks expose the data volume's contents at two paths — `/Users` and
    /// `/System/Volumes/Data/Users` are one directory. Whichever path reaches it first
    /// keeps it, so the data volume's own mount is listed only after everything else:
    /// `/Users`, `/Applications` and `/private` stay on the top ring where they belong,
    /// and the mount only adds what no firmlink exposes.
    private static let dataVolumeMount = "/System/Volumes/Data"

    func run() async throws {
        let rootName = root.path == "/" ? "Macintosh HD" : root.lastPathComponent
        let rootNode = FileNode(url: root, name: rootName, isDirectory: true, size: 0)
        var rootStat = stat()
        let rootStatted = stat(root.path, &rootStat) == 0
        let state = WalkState(rootDev: rootStatted ? rootStat.st_dev : nil)

        // Volumes mounted under the scan root are known from the mount table, so they
        // go in before the walk starts and show up in the very first live snapshot.
        attachSiblingVolumes(to: rootNode, state: state)
        if rootStatted { state.visitedDirs.insert(InodeKey(dev: rootStat.st_dev, ino: UInt64(rootStat.st_ino))) }
        state.pending = [PendingDir(node: rootNode, path: root.path)]

        let group = DispatchGroup()
        for _ in 0..<Self.workerCount {
            group.enter()
            let worker = Thread { [self] in
                work(state)
                group.leave()
            }
            worker.stackSize = 512 * 1024
            worker.qualityOfService = .userInitiated
            worker.start()
        }
        let monitorThread = Thread { [self] in self.monitor(rootNode, state) }
        monitorThread.qualityOfService = .userInitiated
        monitorThread.start()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                group.notify(queue: .global()) { done.resume() }
            }
        } onCancel: {
            state.cancel()
        }

        if state.finish() { throw ScanError.cancelled }
        onProgress(state.finalProgress())
        onComplete(rootNode)
    }

    // MARK: - Workers

    private func work(_ state: WalkState) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            state.queue.lock()
            while state.pending.isEmpty && state.active > 0 && !state.cancelled {
                state.queue.wait()
            }
            if state.cancelled {
                state.queue.unlock()
                return
            }
            if state.pending.isEmpty {
                // Nothing queued and nobody working: everything reachable outside the
                // data volume is counted, so release it — or stop.
                if state.deferred.isEmpty {
                    state.queue.broadcast()
                    state.queue.unlock()
                    return
                }
                state.pending = state.deferred
                state.deferred = []
            }
            let dir = state.pending.removeLast()
            state.active += 1
            state.queue.unlock()

            let (next, later) = list(dir, state: state, buffer: buffer)

            state.queue.lock()
            state.pending += next
            state.deferred += later
            state.active -= 1
            state.queue.broadcast()
            state.queue.unlock()
        }
    }

    /// Lists one directory, attaches its entries, rolls its files' bytes up the tree
    /// and returns the subdirectories to visit (now, and after everything else).
    private func list(_ dir: PendingDir, state: WalkState,
                      buffer: UnsafeMutableRawPointer) -> ([PendingDir], [PendingDir]) {
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            state.tree.lock()
            recordDenied(dir.path, state: state)
            state.tree.unlock()
            return ([], [])
        }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
            | attrgroup_t(ATTR_CMN_ERROR)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // Under FSOPT_ATTR_CMN_EXTENDED this group holds extended common attributes.
        // Volumes without clones (exFAT, HFS+, FAT, SMB) just leave them out.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)

        var files: [FileNode] = []
        var bytes: Int64 = 0
        var shared: [(key: StreamKey, node: FileNode, bytes: Int64)] = []
        var subdirs: [(key: InodeKey, name: String)] = []

        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count <= 0 { break }
            var entry = buffer
            for _ in 0..<count {
                // Each entry: its length, the set of attributes actually returned, then
                // those attributes — the error first, the rest in bit order, groups in
                // order (common, directory, file, extended). Directory attributes come
                // only for directories and file attributes only for files, so the set
                // decides what to read; never assume a fixed layout.
                let length = entry.load(as: UInt32.self)
                let returned = (entry + 4).loadUnaligned(as: attribute_set_t.self)
                defer { entry += Int(length) }
                var p = entry + 4 + MemoryLayout<attribute_set_t>.size
                func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bit) != 0 }

                var error: UInt32 = 0
                if has(returned.commonattr, ATTR_CMN_ERROR) { error = p.loadUnaligned(as: UInt32.self); p += 4 }
                guard error == 0, has(returned.commonattr, ATTR_CMN_NAME) else { continue }
                let name = String(cString: (p + Int(p.loadUnaligned(as: Int32.self))).assumingMemoryBound(to: CChar.self))
                p += MemoryLayout<attrreference_t>.size
                var dev: dev_t = 0
                if has(returned.commonattr, ATTR_CMN_DEVID) { dev = p.loadUnaligned(as: dev_t.self); p += 4 }
                var type: UInt32 = 0
                if has(returned.commonattr, ATTR_CMN_OBJTYPE) { type = p.loadUnaligned(as: UInt32.self); p += 4 }
                var ino: UInt64 = 0
                if has(returned.commonattr, ATTR_CMN_FILEID) { ino = p.loadUnaligned(as: UInt64.self); p += 8 }
                var mountStatus: UInt32 = 0
                if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) { mountStatus = p.loadUnaligned(as: UInt32.self); p += 4 }
                var links: UInt32 = 1
                if has(returned.fileattr, ATTR_FILE_LINKCOUNT) { links = p.loadUnaligned(as: UInt32.self); p += 4 }
                var allocated: Int64 = 0
                if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) {
                    allocated = p.loadUnaligned(as: Int64.self); p += 8
                } else if type != UInt32(VDIR.rawValue) {
                    // FAT volumes don't report it in bulk; ask for this file alone.
                    var st = stat()
                    if lstat(Self.join(dir.path, name), &st) == 0 { allocated = Int64(st.st_blocks) * 512 }
                }
                var cloneID: UInt64 = 0
                if has(returned.forkattr, ATTR_CMNEXT_CLONEID) { cloneID = p.loadUnaligned(as: UInt64.self); p += 8 }
                // A count of 0 or 1 means an unshared stream, so the vast majority of
                // files never reach the owners table. Unknown counts are checked anyway.
                var cloneRefs: UInt32 = 2
                if has(returned.forkattr, ATTR_CMNEXT_CLONE_REFCNT) { cloneRefs = p.loadUnaligned(as: UInt32.self) }

                if type == UInt32(VDIR.rawValue) {
                    var key = InodeKey(dev: dev, ino: ino)
                    // A mount point reports the attributes of the file system *under*
                    // it, so ask the mounted one. An APFS volume group shares one
                    // st_dev, so the data volume isn't a boundary and is still reached;
                    // a different st_dev means another filesystem, whose usage (if it
                    // belongs in the total) is already a sibling node.
                    if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 {
                        var st = stat()
                        guard stat(Self.join(dir.path, name), &st) == 0 else { continue }
                        key = InodeKey(dev: st.st_dev, ino: UInt64(st.st_ino))
                    }
                    if let rootDev = state.rootDev, key.dev != rootDev { continue }
                    subdirs.append((key, name))
                } else if cloneID != 0 && (links > 1 || cloneRefs > 1) {
                    // Hard links and APFS clones are one stream of bytes under several
                    // names. `settle` decides below which of them carries the bytes.
                    let node = FileNode(name: name, isDirectory: false, size: 0, fileCount: 1, parent: dir.node)
                    files.append(node)
                    shared.append((StreamKey(dev: dev, id: cloneID), node, allocated))
                } else if links > 1 {
                    let node = FileNode(name: name, isDirectory: false, size: 0, fileCount: 1, parent: dir.node)
                    files.append(node)
                    shared.append((StreamKey(dev: dev, id: ino), node, allocated))
                } else {
                    // Symlinks land here too: measured, never followed.
                    files.append(FileNode(name: name, isDirectory: false, size: allocated, fileCount: 1,
                                          parent: dir.node))
                    bytes += allocated
                }
            }
        }

        var next: [PendingDir] = []
        var later: [PendingDir] = []
        state.tree.lock()
        var children = files
        for sub in subdirs where state.visitedDirs.insert(sub.key).inserted {
            // Same inode seen before: a firmlink pointing at a directory we counted.
            let node = FileNode(name: sub.name, isDirectory: true, size: 0, fileCount: 0, parent: dir.node)
            children.append(node)
            let path = Self.join(dir.path, sub.name)
            if path == Self.dataVolumeMount {
                later.append(PendingDir(node: node, path: path))
            } else {
                next.append(PendingDir(node: node, path: path))
            }
        }
        dir.node.setChildrenDuringScan(children)
        var ancestor: FileNode? = dir.node
        while let a = ancestor {
            a.accumulateDuringScan(bytes: bytes, files: files.count)
            ancestor = a.parent
        }
        state.progress.fileCount += files.count
        state.progress.byteCount += bytes
        state.progress.currentName = topLevelName(dir.path)
        for item in shared {
            settle(item.key, node: item.node, path: Self.join(dir.path, item.node.name), bytes: item.bytes, state: state)
        }
        state.tree.unlock()
        return (next, later)
    }

    /// Charges a shared stream's bytes to exactly one of its names. Workers reach the
    /// names in no particular order, so the choice follows a fixed rule instead of
    /// arrival: the charge moves whenever a better-placed name turns up, and every scan
    /// ends with the same owner. Callers hold the tree lock.
    private func settle(_ key: StreamKey, node: FileNode, path: String, bytes: Int64, state: WalkState) {
        if let owner = state.streamOwners[key] {
            guard Self.isBetterOwner(path, than: owner.path) else { return }
            charge(owner.node, -owner.bytes, state: state)
        }
        charge(node, bytes, state: state)
        state.streamOwners[key] = StreamOwner(node: node, path: path, bytes: bytes)
    }

    /// Adds bytes to a file and every folder above it. Callers hold the tree lock.
    private func charge(_ node: FileNode, _ bytes: Int64, state: WalkState) {
        var current: FileNode? = node
        while let n = current {
            n.accumulateDuringScan(bytes: bytes, files: 0)
            current = n.parent
        }
        state.progress.byteCount += bytes
    }

    /// Copies outside temp folders win, so Chrome's launch-time clones in
    /// `/private/var/folders` never take the bytes from Chrome.app. Then the shorter
    /// path, then alphabetical, purely to make the choice the same on every run.
    private static func isBetterOwner(_ path: String, than other: String) -> Bool {
        let (disposable, otherDisposable) = (isDisposable(path), isDisposable(other))
        if disposable != otherDisposable { return otherDisposable }
        if path.utf8.count != other.utf8.count { return path.utf8.count < other.utf8.count }
        return path < other
    }

    private static let disposableRoots: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/",
                home + "/Library/Caches/", home + "/.Trash/"]
    }()

    private static func isDisposable(_ path: String) -> Bool {
        let plain = path.hasPrefix(dataVolumeMount + "/") ? String(path.dropFirst(dataVolumeMount.count)) : path
        return disposableRoots.contains { plain.hasPrefix($0) }
    }

    /// Ships progress and live snapshots until the workers are done.
    private func monitor(_ rootNode: FileNode, _ state: WalkState) {
        var lastSnap = Date.distantPast
        while true {
            Thread.sleep(forTimeInterval: Self.progressInterval)
            state.queue.lock()
            let stop = state.finished || state.cancelled
            state.queue.unlock()
            if stop { return }

            let now = Date()
            let takeSnapshot = liveSnapshots && now.timeIntervalSince(lastSnap) > Self.snapshotInterval
            state.tree.lock()
            let progress = state.progress
            let snapshot = takeSnapshot
                ? Self.snapshot(rootNode, depth: Self.snapshotDepth, budget: Self.snapshotBudget) : nil
            state.tree.unlock()
            onProgress(progress)
            if let snapshot {
                lastSnap = now
                onSnapshot(snapshot)
            }
        }
    }

    // MARK: - Helpers

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

    /// Notes a directory the scan couldn't list, split by whether the user can fix it.
    /// Callers hold the tree lock.
    ///
    /// Full Disk Access is a TCC grant over the user's *own* protected data. It does
    /// nothing for a root-owned directory with no world permissions — `/private/var/db/*`,
    /// `/System/Library/Templates` and the like stay closed however many toggles are on.
    private func recordDenied(_ path: String, state: WalkState) {
        var st = stat()
        // If even stat fails we can't attribute it — count it as protected rather than
        // claim Full Disk Access would help.
        if stat(path, &st) == 0 && st.st_uid == getuid() {
            state.progress.deniedFixable += 1
        } else {
            state.progress.deniedProtected += 1
        }
        if state.progress.deniedPaths.count < Self.deniedPathSampleLimit {
            state.progress.deniedPaths.append(path)
        }
    }

    /// The scan root's child that `path` sits under, for the status line.
    private func topLevelName(_ path: String) -> String {
        let rootPath = root.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return "" }
        return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
    }

    private static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    /// A directories-only copy for the live chart. Built **breadth-first** so shallow,
    /// large folders (the visible inner rings, e.g. every top-level of the disk) are
    /// always included; the node `budget` only truncates the deepest, smallest slices.
    /// Cost stays flat no matter how big the tree gets — the full, unbounded tree is
    /// delivered once via `onComplete`. Sizes already include every file so far.
    private static func snapshot(_ root: FileNode, depth: Int, budget: Int) -> FileNode {
        // Copies carry their URL, built from the parent copy's in one step; asking the
        // original for `url` would walk its whole parent chain for every node, all
        // while the workers wait on the tree lock.
        func shallowCopy(_ n: FileNode, under parentURL: URL?) -> FileNode {
            let url = n.isSynthetic ? n.url
                : parentURL.map { $0.appendingPathComponent(n.name, isDirectory: n.isDirectory) } ?? n.url
            return FileNode(url: url, name: n.name, isDirectory: n.isDirectory,
                            size: n.size, fileCount: n.fileCount, isSynthetic: n.isSynthetic)
        }
        let rootCopy = shallowCopy(root, under: nil)
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
                let childCopy = shallowCopy(child, under: item.copy.url)
                copies.append(childCopy)
                queue.append((child, childCopy, item.depth - 1))
            }
            if !copies.isEmpty { item.copy.replaceChildrenForSnapshot(copies) }
        }
        return rootCopy
    }
}
