import SwiftUI

/// Drives the update UI: a silent check on launch, then download + in-place install.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case downloading(Double)   // 0…1
        case installing
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var dismissed = false

    private let service = UpdateService()

    var currentVersion: String { service.currentVersion }

    /// The update banner shows only for an available update the user hasn't dismissed,
    /// or while actively downloading/installing/failed.
    var bannerInfo: UpdateInfo? {
        if case .available(let info) = phase, !dismissed { return info }
        return nil
    }

    /// Quiet check shortly after launch. Only surfaces a result if an update exists.
    func checkOnLaunch() {
        guard case .idle = phase else { return }
        Task {
            if let info = try? await service.checkForUpdate() {
                phase = .available(info)
                dismissed = false
            }
        }
    }

    /// Explicit check (e.g. a menu command): always reports the outcome.
    func checkNow() {
        phase = .checking
        dismissed = false
        Task {
            do {
                if let info = try await service.checkForUpdate() {
                    phase = .available(info)
                } else {
                    phase = .upToDate
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Download the update and swap it in. Falls back to opening the release page
    /// if the release has no downloadable app.
    func installUpdate(_ info: UpdateInfo) {
        guard info.assetUrl != nil else {
            service.openReleasePage(info)
            return
        }
        phase = .downloading(0)
        Task {
            do {
                let archive = try await service.download(info) { p in
                    Task { @MainActor in self.phase = .downloading(p) }
                }
                phase = .installing
                try service.installAndRelaunch(archive: archive)   // terminates on success
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
