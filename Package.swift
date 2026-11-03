// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMidiRouter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MidiRouterCore"),
        .executableTarget(
            name: "MidiRouterApp",
            dependencies: ["MidiRouterCore"]
        ),
        .testTarget(
            name: "MidiRouterCoreTests",
            dependencies: ["MidiRouterCore"]
        ),
    ]
)
