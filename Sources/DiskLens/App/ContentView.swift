import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var annotations: AnnotationCenter
    @AppStorage("appLanguage") private var langRaw = Lang.initial.rawValue
    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    @State private var deniedDismissed = false
    @State private var deniedListShown = false
    @State private var claudeDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            ScanBar()
            Divider()
            if let info = updater.bannerInfo {
                updateBanner(info)
                Divider()
            } else if updateBusy {
                updateProgressBanner
                Divider()
            }
            if state.progress.deniedCount > 0 && !deniedDismissed {
                deniedBanner
                Divider()
            }
            if !annotations.items.isEmpty && !claudeDismissed {
                ClaudeBanner(dismissed: $claudeDismissed)
                Divider()
            }
            content
        }
        .frame(minWidth: 820, minHeight: 560)
        .overlay(alignment: .bottom) { toast }
        .onAppear {
            scanLaunchArgumentIfPresent()
            updater.checkOnLaunch()
        }
        .onChange(of: state.isScanning) { _, scanning in
            if scanning { deniedDismissed = false; deniedListShown = false }
        }
        // New marks bring a dismissed banner back.
        .onChange(of: annotations.updatedAt) { _, _ in claudeDismissed = false }
    }

    private var updateBusy: Bool {
        switch updater.phase {
        case .downloading, .installing, .failed: return true
        default: return false
        }
    }

    private func updateBanner(_ info: UpdateInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text(String(format: L(.updateAvailable, lang), info.version))
                .font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            Button(L(.updateNow, lang)) { updater.installUpdate(info) }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button(L(.updateLater, lang)) { updater.dismissed = true }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.blue.opacity(0.12))
    }

    @ViewBuilder
    private var updateProgressBanner: some View {
        HStack(spacing: 10) {
            switch updater.phase {
            case .downloading(let p):
                ProgressView(value: p).frame(width: 120)
                Text(String(format: L(.updateDownloading, lang), Int(p * 100)))
                    .font(.callout).monospacedDigit()
            case .installing:
                ProgressView().controlSize(.small)
                Text(L(.updateInstalling, lang)).font(.callout)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(L(.updateFailed, lang)): \(msg)").font(.callout).lineLimit(1)
            default:
                EmptyView()
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.blue.opacity(0.10))
    }

    private var deniedBanner: some View {
        let progress = state.progress
        let fixable = progress.deniedFixable
        let protectedOnly = fixable == 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: protectedOnly ? "lock.shield" : "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(deniedMessage)
                    .font(.callout).lineLimit(2)
                Spacer(minLength: 8)
                Button(deniedListShown ? L(.deniedHideFolders, lang) : L(.deniedShowFolders, lang)) {
                    deniedListShown.toggle()
                }
                .buttonStyle(.borderless).controlSize(.small)
                // Only offer the toggle when it can actually change the outcome —
                // root-owned directories stay closed no matter what TCC says.
                if fixable > 0 {
                    Button(L(.grantFullDiskAccess, lang)) { state.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button {
                    deniedDismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L(.deniedDismiss, lang))
            }
            if deniedListShown { deniedList }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var deniedMessage: String {
        let progress = state.progress
        if progress.deniedFixable == 0 {
            return String(format: L(.deniedBannerProtected, lang), progress.deniedProtected)
        }
        if progress.deniedProtected == 0 {
            return String(format: L(.deniedBanner, lang), progress.deniedFixable)
        }
        return String(format: L(.deniedBannerMixed, lang), progress.deniedCount,
                      progress.deniedFixable, progress.deniedProtected)
    }

    private var deniedList: some View {
        let paths = state.progress.deniedPaths
        let hidden = state.progress.deniedCount - paths.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .font(.caption).monospaced()
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if hidden > 0 {
                    Text(String(format: L(.deniedListMore, lang), hidden))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 130)
    }

    /// If launched with a directory path argument (`open -a DiskLens --args /path`),
    /// scan it immediately instead of showing the empty state.
    private func scanLaunchArgumentIfPresent() {
        guard state.root == nil, !state.isScanning else { return }
        for arg in CommandLine.arguments.dropFirst() where arg.hasPrefix("/") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                // Defer to the next runloop so the window finishes presenting before
                // the scan flips the view to the live chart.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    state.scan(URL(fileURLWithPath: arg))
                }
                return
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.root != nil {
            HSplitView {
                SunburstView()
                    .frame(minWidth: 380)
                    .padding(6)
                DetailPanel()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
            }
        } else if state.isScanning {
            scanningPlaceholder
        } else {
            EmptyStateView()
        }
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(L(.scanning, lang)).font(.headline)
            Text(String(format: L(.scanningDetail, lang),
                        state.progress.fileCount, state.progress.byteCount.humanBytes))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = state.toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
                .shadow(radius: 8, y: 2)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Shown before any scan: intro + quick picks for common folders.
struct EmptyStateView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("appLanguage") private var langRaw = Lang.initial.rawValue
    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor.gradient)
            VStack(spacing: 6) {
                Text(L(.emptyTitle, lang)).font(.title2).bold()
                Text(L(.emptyHint, lang))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button {
                state.chooseFolderAndScan()
            } label: {
                Label(L(.chooseFolder, lang), systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            quickPicks
            Text(L(.permissionHint, lang))
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var quickPicks: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let picks: [(String, String, URL)] = [
            (L(.quickPickWholeDisk, lang), "internaldrive", URL(fileURLWithPath: "/")),
            (L(.quickPickHome, lang), "house", home),
            (L(.quickPickDownloads, lang), "arrow.down.circle", home.appendingPathComponent("Downloads")),
            (L(.quickPickDocuments, lang), "doc.text", home.appendingPathComponent("Documents")),
            (L(.quickPickDesktop, lang), "desktopcomputer", home.appendingPathComponent("Desktop")),
        ]
        return HStack(spacing: 8) {
            ForEach(picks, id: \.0) { name, icon, url in
                Button {
                    state.scan(url)
                } label: {
                    Label(name, systemImage: icon)
                        .font(.callout)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 4)
    }
}
