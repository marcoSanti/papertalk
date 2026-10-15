// swift-tools-version:6.0
// Spike S1 (docs/LINUX_PORT.md): can SwiftCrossUI (GTK 4) drive Papertalk's kind of UI
// from an AppStore-like ObservableObject that uses OpenCombine, as AppStore would on Linux?
import PackageDescription

let package = Package(
    name: "GtkSpike",
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.9.0"),
        .package(url: "https://github.com/OpenCombine/OpenCombine", from: "0.14.0"),
    ],
    targets: [
        // Stands in for PapertalkCore: no UI imports, Combine-style state.
        .target(name: "SpikeCore", dependencies: ["OpenCombine"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "SpikeGTK", dependencies: [
            "SpikeCore",
            .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
            .product(name: "GtkBackend", package: "swift-cross-ui"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
