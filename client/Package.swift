// swift-tools-version:6.2
import PackageDescription

// One target for both platforms (AGENTS.md, "Linux port"). macOS builds exactly what it
// always has; Linux swaps the Apple frameworks for compat shims in Linux/,
// backed by Python through PythonKit, and adds its own UI on SwiftCrossUI (GTK 4).
let package = Package(
    name: "Papertalk",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.7"),
        // Linux only (see the conditions below).
        .package(url: "https://github.com/pvieito/PythonKit", revision: "e1d34f95c58189b771bfc8423b9b2cf8fc651664"),
        .package(url: "https://github.com/OpenCombine/OpenCombine", from: "0.14.0"),
        .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Papertalk",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio", condition: .when(platforms: [.macOS])),
                .product(name: "PythonKit", package: "PythonKit", condition: .when(platforms: [.linux])),
                .product(name: "OpenCombine", package: "OpenCombine", condition: .when(platforms: [.linux])),
                .product(name: "OpenCombineDispatch", package: "OpenCombine", condition: .when(platforms: [.linux])),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui", condition: .when(platforms: [.linux])),
                .product(name: "GtkBackend", package: "swift-cross-ui", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/Papertalk",
            exclude: ["macOS/Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PapertalkTests",
            dependencies: ["Papertalk"],
            path: "Tests/PapertalkTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
