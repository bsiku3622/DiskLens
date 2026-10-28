import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Root of the last completed scan.
    @Published var root: FileNode?
    /// Node currently at the center of the sunburst (drill-down position).
    @Published var focus: FileNode?
    /// Slice the pointer is hovering, for highlight + center label.
    @Published var hovered: FileNode?
    /// Row/slice picked for the detail actions.
    @Published var selected: FileNode?

    @Published var isScanning = false
    @Published var progress = ScanProgress()
    @Published var scannedURL: URL?
    @Published var errorMessage: String?
    @Published var toast: String?
    /// Mount layout for the current scan: sibling volumes and what the disk really holds.
    @Published var volumes: VolumeMap?

    private var scanTask: Task<Void, Never>?
    /// Where to land once the running scan finishes (see `show(path:)`).
    private var pendingFocusPath: String?

    // MARK: - Scanning

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L(.chooseFolder)
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            scan(url)
        }
    }

    func scan(_ url: URL) {
        scanTask?.cancel()
        errorMessage = nil
        isScanning = true
        progress = ScanProgress()
        scannedURL = url
        hovered = nil
        selected = nil

        // Show an empty root immediately so the live chart has a frame to grow in.
        let name = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
        root = FileNode(url: url, name: name, isDirectory: true, size: 0)
        focus = root

        let volumeMap = VolumeMap(scanRoot: url)
        volumes = volumeMap

        final class LastProgress: @unchecked Sendable { var value = ScanProgress() }
        let last = LastProgress()
        let startedAt = Date()

        // AppState.shared is a permanent singleton, so a strong capture is fine here.
        scanTask = Task {
            let scanner = Scanner(
                root: url,
                volumes: volumeMap,
                onProgress: { p in last.value = p; Task { @MainActor in self.progress = p } },
                onSnapshot: { tree in Task { @MainActor in self.applySnapshot(tree) } },
                onComplete: { tree in
                    // Still on the scan thread, before the tree is handed to the UI and
                    // can change: save it for Claude in the sidebar.
                    CurrentScan.save(HeadlessScan.report(tree, volumes: volumeMap, progress: last.value,
                                                         startedAt: startedAt, minSize: CurrentScan.minSize,
                                                         maxDepth: 64))
                    Task { @MainActor in self.applyComplete(tree) }
                }
            )
            do {
                try await scanner.run()
            } catch is CancellationError {
                return
            } catch ScanError.cancelled {
                return
            } catch {
                self.failScan(error)
            }
        }
    }

    /// A live, partial tree arrived mid-scan: swap it in and keep the view at root.
    private func applySnapshot(_ tree: FileNode) {
        guard isScanning else { return }
        root = tree
        focus = tree
        hovered = nil
        selected = nil
    }

    /// The final, complete tree.
    private func applyComplete(_ tree: FileNode) {
        root = tree
        focus = tree
        isScanning = false
        progress.currentName = ""
        hovered = nil
        selected = nil
        if let path = pendingFocusPath {
            pendingFocusPath = nil
            _ = focus(path: path)
        }
        objectWillChange.send()
        AgentChat.shared.scanFinished(completed: true)
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        progress.currentName = ""
        AgentChat.shared.scanFinished(completed: false)
    }

    func rescan() {
        guard let url = scannedURL else { return }
        scan(url)
    }

    private func failScan(_ error: Error) {
        isScanning = false
        errorMessage = L(.scanFailed)
        AgentChat.shared.scanFinished(completed: false)
    }

    // MARK: - Navigation

    func drill(into node: FileNode) {
        guard node.isDirectory, !node.sortedChildren.isEmpty else {
            selected = node
            return
        }
        focus = node
        selected = nil
        hovered = nil
    }

    func focusUp() {
        guard let parent = focus?.parent else { return }
        focus = parent
        selected = nil
        hovered = nil
    }

    func setFocus(_ node: FileNode) {
        focus = node
        selected = nil
        hovered = nil
    }

    /// Brings `path` into view: a folder becomes the focus, a file is selected inside
    /// its folder. Outside the current scan, scans the item's folder first.
    func show(path: String) {
        if focus(path: path) { return }
        pendingFocusPath = path
        scan(URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    /// Drops an item that was trashed outside the app (by Claude in the sidebar) from
    /// the tree, the same way `moveToTrash` does after trashing it itself.
    func removeNode(path: String) {
        guard let node = node(at: path), let parent = node.parent, !node.isSynthetic else { return }
        parent.removeChild(node)
        if selected?.id == node.id { selected = nil }
        if hovered?.id == node.id { hovered = nil }
        // The trashed item may be the focused folder or one of its ancestors.
        if let focus, focus.ancestry.contains(where: { $0 === node }) { self.focus = parent }
        objectWillChange.send()
    }

    /// Walks down from the root by name. Comparing names, not URLs: scanned nodes
    /// derive their URL from the parent chain, so building one per child is costly.
    private func node(at path: String) -> FileNode? {
        guard let root else { return nil }
        let rootPath = root.url.path
        if path == rootPath { return root }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            // The synthetic volume group shares its parent's path; never descend through it.
            guard let next = node.children.first(where: { !$0.isSynthetic && $0.name == component })
            else { return nil }
            node = next
        }
        return node
    }

    private func focus(path: String) -> Bool {
        guard let node = node(at: path) else { return false }
        if node.isDirectory, !node.sortedChildren.isEmpty {
            setFocus(node)
        } else if let parent = node.parent {
            setFocus(parent)
            selected = node
        }
        return true
    }

    // MARK: - Actions

    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    /// Opens System Settings › Privacy & Security › Full Disk Access so the user
    /// can grant DiskLens access to folders it was blocked from reading.
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func moveToTrash(_ node: FileNode) {
        // Synthetic volume nodes stand in for mount points, not for anything deletable.
        guard !node.isSynthetic, let parent = node.parent else { return }
        do {
            try TrashService.moveToTrash(node.url)
            parent.removeChild(node)
            if selected?.id == node.id { selected = nil }
            if hovered?.id == node.id { hovered = nil }
            // If we trashed the focused folder itself, step up.
            if focus?.id == node.id { focus = parent }
            showToast(L(.trashed))
            objectWillChange.send()
        } catch {
            showToast(L(.trashFailed))
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.toast == message { self.toast = nil }
        }
    }
}
