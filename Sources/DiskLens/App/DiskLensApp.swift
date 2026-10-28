import SwiftUI

/// Launched by `Entry` when no headless command is given.
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @StateObject private var updater = Updater()
    @StateObject private var annotations = AnnotationCenter.shared
    @AppStorage("appLanguage") private var langRaw = Lang.initial.rawValue
    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(updater)
                .environmentObject(annotations)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L(.checkForUpdates, lang)) { updater.checkNow() }
            }
        }
    }
}
