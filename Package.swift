// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HyperWM",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HyperWM",
            path: "Sources/HyperKey",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
