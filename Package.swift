// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DiskLens",
            path: "Sources/DiskLens"
        )
    ]
)
