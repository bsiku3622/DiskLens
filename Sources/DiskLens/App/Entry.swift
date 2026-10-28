import SwiftUI
import AppKit

/// Process entry point. `--export` and `--mcp` run headless and exit when done;
/// anything else (including a bare folder path) launches the app.
@main
enum Entry {
    @MainActor
    static func main() {
        guard let command = HeadlessCommand(arguments: Array(CommandLine.arguments.dropFirst())) else {
            // AppKit treats a bare path argument as a document to open, and a SwiftUI
            // app that opens one at launch never creates its first window — so
            // `open -a DiskLens --args /folder` showed nothing. ContentView reads the
            // folder argument itself.
            UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
            DiskLensApp.main()
            return
        }
        // Launched through `open`, a bundle app gets a Dock icon until it checks in;
        // a headless run never will, so opt out of the Dock entirely.
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task {
            let status = await command.run()
            exit(status)
        }
        dispatchMain()
    }
}
