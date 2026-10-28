import Foundation

/// Command-line modes that run without the UI.
///
///     DiskLens --export <file.json|-> [--min-size 20M] [--max-depth N] <folder>
///     DiskLens --mcp
///
/// To scan with the app's own Full Disk Access grant, launch it through
/// LaunchServices so DiskLens — not the terminal — is the responsible process:
///
///     open -n -W -a DiskLens --args --export /tmp/scan.json /
enum HeadlessCommand {
    case export(output: String, root: URL, minSize: Int64, maxDepth: Int)
    case mcp
    case help
    case invalid(String)

    static let defaultExportMinSize: Int64 = 20_000_000

    /// nil means "not a headless invocation" — launch the app.
    init?(arguments args: [String]) {
        if args.contains("--mcp") { self = .mcp; return }
        if args.contains("--help") || args.contains("-h") { self = .help; return }
        guard args.contains("--export") else { return nil }

        var output: String?
        var minSize = Self.defaultExportMinSize
        var maxDepth = 64
        var folder: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            let value = i + 1 < args.count ? args[i + 1] : nil
            switch arg {
            case "--export":
                guard let value else { self = .invalid("--export needs an output path"); return }
                output = value; i += 2
            case "--min-size":
                guard let value, let n = HeadlessScan.parseSize(value) else {
                    self = .invalid("--min-size needs a size like 20M"); return
                }
                minSize = n; i += 2
            case "--max-depth":
                guard let value, let n = Int(value), n >= 0 else {
                    self = .invalid("--max-depth needs a number"); return
                }
                maxDepth = n; i += 2
            default:
                if arg.hasPrefix("-") { self = .invalid("unknown option \(arg)"); return }
                folder = arg; i += 1
            }
        }
        guard let output, let folder else { self = .invalid("usage: --export <file|-> <folder>"); return }
        let path = AnnotationStore.normalize(folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            self = .invalid("not a folder: \(folder)"); return
        }
        self = .export(output: output, root: URL(fileURLWithPath: path), minSize: minSize, maxDepth: maxDepth)
    }

    func run() async -> Int32 {
        switch self {
        case .mcp:
            return await MCPServer().run()
        case .help:
            Self.stderr(Self.usage)
            return 0
        case .invalid(let message):
            Self.stderr("DiskLens: \(message)\n\n\(Self.usage)")
            return 2
        case let .export(output, root, minSize, maxDepth):
            do {
                let report = try await HeadlessScan.run(root, minSize: minSize, maxDepth: maxDepth)
                let data = try Self.encoder.encode(report)
                if output == "-" {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    try data.write(to: URL(fileURLWithPath: AnnotationStore.normalize(output)), options: .atomic)
                    Self.stderr("DiskLens: scanned \(report.scannedBytes.humanBytes) in \(report.fileCount) files, wrote \(output)\n")
                }
                return 0
            } catch {
                Self.stderr("DiskLens: scan failed: \(error)\n")
                return 1
            }
        }
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    static func stderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    static let usage = """
    Usage:
      DiskLens --export <file.json|-> [--min-size 20M] [--max-depth N] <folder>
          Scan <folder> and write a size-pruned tree as JSON. Items smaller than
          --min-size fold into each folder's "otherSize".
      DiskLens --mcp
          Run as a Model Context Protocol server on stdio.
      DiskLens [<folder>]
          Open the app (and scan <folder>).

    """
}
