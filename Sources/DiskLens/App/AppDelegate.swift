import SwiftUI
import AppKit

/// Ensures the app runs as a regular, foreground app and its window is brought
/// to the front on launch — needed when the executable is started directly
/// (SwiftPM binary) rather than via a fully-configured .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // The WindowGroup window may not exist yet at this point; order it front
        // on the next run loop tick.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
