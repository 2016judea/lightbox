// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lightbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lightbox",
            path: "Sources/Lightbox",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        ),
        .testTarget(name: "LightboxTests", dependencies: ["Lightbox"], path: "Tests/LightboxTests"),
    ]
)
