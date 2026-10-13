// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Papertalk",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.7")
    ],
    targets: [
        .executableTarget(
            name: "Papertalk",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Papertalk",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)