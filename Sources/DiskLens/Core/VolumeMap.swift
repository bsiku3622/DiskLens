import Foundation

/// A snapshot of the mount table, taken when a scan starts.
///
/// The walk can't decide on its own what to do at a mount boundary: `st_dev` says
/// "different filesystem" for both a sibling volume whose bytes belong in the total
/// and the same volume mounted a second time. This resolves that from the device
/// names — APFS mounts a snapshot of `diskNsM` as `diskNsMsK`, so trimming the last
/// component maps a snapshot mount back onto the volume it shadows.
///
/// Sizes come from `getattrlist(ATTR_VOL_SPACEUSED)`, which is what `df` reports as
/// Used. `statfs` can't answer this: every volume in an APFS container reports the
/// *container's* totals, so `f_blocks - f_bfree` is identical across siblings.
struct VolumeMap: Sendable {
    struct Sibling: Sendable {
        let name: String
        let path: String
        let spaceUsed: Int64
    }

    /// Sibling volumes under the scan root, largest first. These become synthetic
    /// nodes so their space is visible without pretending we walked into them.
    let siblings: [Sibling]

    /// Everything the scan root's container actually occupies on disk, counting each
    /// volume once. Used to show real usage next to the scanned total, which runs
    /// high because `totalFileAllocatedSize` bills APFS clones to every clone.
    let containerUsedBytes: Int64

    /// True when the scan starts at a volume's mount point. Only then does the
    /// container total describe the same ground as the scanned total — comparing the
    /// two while scanning one folder would just confuse.
    let scanRootIsVolumeRoot: Bool

    init(scanRoot: URL) {
        let rootPath = scanRoot.path
        let rootDev = Self.deviceID(of: rootPath)
        let rootIdentity = Self.mountDevice(of: rootPath).flatMap(Self.identity)

        var siblings: [Sibling] = []
        var containerTotal: Int64 = 0
        var countedVolumes = Set<String>()
        var siblingVolumes = Set<String>()
        var rootIsVolumeRoot = false

        if let volume = rootIdentity?.volume {
            countedVolumes.insert(volume)
            containerTotal = Self.spaceUsed(rootPath) ?? 0
        }

        for mount in Self.mounts() {
            if mount.point == rootPath { rootIsVolumeRoot = true }
            let identity = Self.identity(mount.device)

            // Container total spans the whole disk regardless of where the scan is
            // rooted, so it's tallied before the scan-root and boundary filtering.
            if let identity, identity.container == rootIdentity?.container,
               countedVolumes.insert(identity.volume).inserted {
                containerTotal += Self.spaceUsed(mount.point) ?? 0
            }

            guard mount.point != rootPath, Self.isUnder(mount.point, rootPath) else { continue }

            // An APFS volume group (the read-only system volume plus its data volume)
            // shares one st_dev and is stitched together by firmlinks, so the walk
            // already reaches the data volume through `/Users`, `/private` and friends.
            // Only a differing st_dev is a real boundary.
            guard let mountDev = Self.deviceID(of: mount.point), mountDev != rootDev else { continue }

            // A foreign container, a different physical disk, or a pseudo filesystem
            // (devfs, autofs): none of it is this disk's usage.
            guard let identity, identity.container == rootIdentity?.container else { continue }
            // The same volume mounted a second time. macOS remounts the sealed system
            // snapshot at `/System/Volumes/Update/mnt1`, where it mirrors all of `/`.
            guard identity.volume != rootIdentity?.volume,
                  siblingVolumes.insert(identity.volume).inserted else { continue }

            siblings.append(Sibling(name: (mount.point as NSString).lastPathComponent,
                                    path: mount.point,
                                    spaceUsed: Self.spaceUsed(mount.point) ?? 0))
        }

        self.siblings = siblings.sorted { $0.spaceUsed > $1.spaceUsed }
        self.containerUsedBytes = containerTotal
        self.scanRootIsVolumeRoot = rootIsVolumeRoot
    }

    // MARK: - Filesystem plumbing

    private struct Mount { let point: String; let device: String }

    private static func mounts() -> [Mount] {
        var buf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buf, MNT_NOWAIT)
        guard count > 0, let buf else { return [] }
        return (0..<Int(count)).map {
            Mount(point: fixedCString(buf[$0].f_mntonname),
                  device: fixedCString(buf[$0].f_mntfromname))
        }
    }

    /// "/dev/disk3s1s1" → (container: "disk3", volume: "disk3s1").
    /// Returns nil for anything that isn't a disk device (devfs, autofs, network).
    private static func identity(_ device: String) -> (container: String, volume: String)? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        // Strip the literal "disk" before splitting — otherwise its own "s" splits too.
        let parts = device.dropFirst("/dev/disk".count)
            .split(separator: "s", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        let container = "disk" + parts[0]
        return (container, container + "s" + parts[1])
    }

    /// Bytes this volume occupies in its container — the number `df` prints as Used.
    private static func spaceUsed(_ path: String) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buf = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &list, &buf, buf.count, 0) == 0 else { return nil }
        // Packed reply: u_int32_t length, then off_t spaceused.
        let used = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        return used >= 0 ? used : nil
    }

    private static func deviceID(of path: String) -> dev_t? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_dev
    }

    private static func mountDevice(of path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return fixedCString(s.f_mntfromname)
    }

    private static func isUnder(_ path: String, _ ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// Reads a C fixed-size char array (imported as a tuple) as a String.
    private static func fixedCString<T>(_ tuple: T) -> String {
        var value = tuple
        return withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
