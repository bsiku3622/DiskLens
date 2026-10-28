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
        if case .export = command {
            // `open -n -W -a DiskLens --args --export …` launches through LaunchServices,
            // which shows a Dock icon until the app checks in; a headless run never
            // will, so opt out of the Dock.
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
        // Never touch AppKit in --mcp: NSApplication.shared registers the process with
        // LaunchServices as a running DiskLens, and agents keep MCP servers alive for
        // hours. Opening the app then tries to bring that headless process forward and
        // fails with "DiskLens can't be opened".
        Task {
            let status = await command.run()
            exit(status)
        }
        dispatchMain()
    }
}
