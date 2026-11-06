// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FT891Control",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FT891Control",
            path: "Sources/FT891Control"
        )
    ]
)
