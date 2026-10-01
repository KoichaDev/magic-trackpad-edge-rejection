// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackpadEdges",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "TrackpadEdges", targets: ["TrackpadEdges"])],
    targets: [
        .target(name: "MultitouchAdapter", linkerSettings: [
            .linkedFramework("CoreFoundation"), .linkedFramework("IOKit")
        ]),
        .target(name: "EdgeModel"),
        .executableTarget(name: "TrackpadEdges", dependencies: ["MultitouchAdapter", "EdgeModel"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon")]),
        // Standalone checks work with Command Line Tools, without Xcode's
        // XCTest/Swift Testing runtime and overlay modules.
        .executableTarget(name: "EdgeModelChecks", dependencies: ["EdgeModel"], path: "Tests/EdgeModelTests")
    ],
    swiftLanguageModes: [.v5]
)
