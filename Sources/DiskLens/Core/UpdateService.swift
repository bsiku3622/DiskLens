import Foundation
import AppKit

/// Minimal subset of a GitHub release we care about.
struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let body: String?
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Codable {
        let name: String
        let browserDownloadUrl: String
        let size: Int64
    }
}

/// A newer release resolved for this platform.
struct UpdateInfo: Equatable {
    let version: String         // normalized, e.g. "0.2.0"
    let releaseNotes: String
    let pageUrl: String
    let assetUrl: String?       // direct download; nil → open the page
    let assetName: String?
    let assetSize: Int64
}

enum UpdateError: LocalizedError {
    case http(Int)
    case noAsset
    case badResponse
    case badArchive

    var errorDescription: String? {
        switch self {
        case .http(let c): return "GitHub returned \(c)"
        case .noAsset: return "No downloadable build in this release"
        case .badResponse: return "Unexpected response"
        case .badArchive: return "Downloaded update was not a valid app"
        }
    }
}

/// Checks GitHub Releases for a newer build, downloads the macOS asset, and can
/// swap the running app in place and relaunch.
final class UpdateService {
    static let repo = "bsiku3622/DiskLens"

    /// This build's version, read from the bundle (falls back to 0.0.0 in dev runs).
    let currentVersion: String

    init() {
        currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Returns update details if the latest release is newer than the running build, else nil.
    func checkForUpdate() async throws -> UpdateInfo? {
        let release = try await latestRelease()
        let latest = Self.normalize(release.tagName)
        guard Self.isNewer(latest, than: currentVersion) else { return nil }
        let asset = Self.macAsset(release.assets)
        return UpdateInfo(version: latest,
                          releaseNotes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                          pageUrl: release.htmlUrl, assetUrl: asset?.browserDownloadUrl,
                          assetName: asset?.name, assetSize: asset?.size ?? 0)
    }

    /// Downloads the asset to a temp location and returns its local URL.
    func download(_ info: UpdateInfo, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let urlStr = info.assetUrl, let url = URL(string: urlStr) else { throw UpdateError.noAsset }
        let delegate = DownloadProgressDelegate(onProgress: progress)
        let (tempURL, resp) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.http(http.statusCode) }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(info.assetName ?? url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    /// Unzips the downloaded archive, then hands off to a small detached script that
    /// waits for this process to quit, swaps the new build over the running bundle,
    /// and relaunches it. Terminates the app on success.
    func installAndRelaunch(archive: URL) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("DiskLensUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Unzip with ditto (handles the ditto/zip format release.sh produces).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, workDir.path]
        try unzip.run()
        unzip.waitUntilExit()

        guard let newApp = fm.enumerator(at: workDir, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL })
                .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.badArchive
        }

        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = workDir.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf "\(bundlePath)"
        /usr/bin/ditto "\(newApp.path)" "\(bundlePath)"
        /usr/bin/open "\(bundlePath)"
        /bin/rm -rf "\(workDir.path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = [script.path]
        try runner.run()

        NSApp.terminate(nil)
    }

    /// Opens the release page in the browser (fallback when there's no asset).
    func openReleasePage(_ info: UpdateInfo) {
        if let url = URL(string: info.pageUrl) { NSWorkspace.shared.open(url) }
    }

    // MARK: networking

    private func latestRelease() async throws -> GitHubRelease {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(GitHubRelease.self, from: data)
    }

    // MARK: asset selection + version compare

    /// Prefers a mac-tagged .zip, then any .zip, then a .dmg.
    static func macAsset(_ assets: [GitHubRelease.Asset]) -> GitHubRelease.Asset? {
        assets.first { let n = $0.name.lowercased(); return n.contains("mac") && n.hasSuffix(".zip") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".zip") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func isNewer(_ a: String, than b: String) -> Bool { compare(a, b) > 0 }

    /// semver-ish: numeric major.minor.patch; a pre-release (`-…`) ranks below its release.
    static func compare(_ a: String, _ b: String) -> Int {
        let (av, ap) = splitPre(a)
        let (bv, bp) = splitPre(b)
        for i in 0..<3 where av[i] != bv[i] { return av[i] < bv[i] ? -1 : 1 }
        if ap.isEmpty != bp.isEmpty { return ap.isEmpty ? 1 : -1 }
        if ap != bp { return ap < bp ? -1 : 1 }
        return 0
    }

    private static func splitPre(_ s: String) -> ([Int], String) {
        let parts = s.split(separator: "-", maxSplits: 1)
        var nums = (parts.first.map(String.init) ?? "0").split(separator: ".").map { Int($0) ?? 0 }
        while nums.count < 3 { nums.append(0) }
        return (Array(nums.prefix(3)), parts.count > 1 ? String(parts[1]) : "")
    }
}

/// Reports download progress via the session delegate's didWriteData.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
