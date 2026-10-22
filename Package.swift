// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lightbox",
    platforms: [.macOS(.v14)],
    dependencies: [
        // HNSW vector index for the Photos lab-scan matcher (Apache-2.0)
        .package(url: "https://github.com/unum-cloud/usearch.git", exact: "2.26.5"),
    ],
    targets: [
        .executableTarget(
            name: "Lightbox",
            dependencies: [.product(name: "USearch", package: "usearch")],
            path: "Sources/Lightbox",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "LightboxTests", dependencies: ["Lightbox"], path: "Tests/LightboxTests"),
    ]
)
