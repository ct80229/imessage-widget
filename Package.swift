// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iMessageWidget",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "iMessageWidget",
            path: "Sources/iMessageWidget",
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"])
            ]
        )
    ]
)
