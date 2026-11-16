// swift-tools-version:6.2
import PackageDescription

// One target for both platforms (AGENTS.md, "Linux port"). macOS builds exactly what it
// always has; Linux swaps the Apple frameworks for compat shims in Linux/, backed by
// C libraries (sherpa-onnx for Kokoro, poppler for PDFs, libsecret for the keyring),
// and adds its own UI on SwiftCrossUI (GTK 4).

/// The C libraries behind the Linux shims. Declared only when the manifest is read on
/// Linux, so macOS never probes pkg-config for them.
#if os(Linux)
let linuxSystemTargets: [Target] = [
    // Kokoro on ONNX Runtime: libsherpa-onnx-c-api.so (and libonnxruntime.so) from a
    // sherpa-onnx release, found through the sherpa-onnx.pc that
    // client/linux-dev/install_sherpa.sh writes.
    .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx", pkgConfig: "sherpa-onnx"),
    .systemLibrary(name: "CPoppler", path: "Sources/CPoppler", pkgConfig: "poppler-glib",
                   providers: [.apt(["libpoppler-glib-dev"])]),
    .systemLibrary(name: "CSecret", path: "Sources/CSecret", pkgConfig: "libsecret-1",
                   providers: [.apt(["libsecret-1-dev"])]),
]
let linuxSystemDependencies: [Target.Dependency] = ["CSherpaOnnx", "CPoppler", "CSecret"]
#else
let linuxSystemTargets: [Target] = []
let linuxSystemDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "Papertalk",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.7"),
        // Linux only (see the conditions below).
        .package(url: "https://github.com/OpenCombine/OpenCombine", from: "0.14.0"),
        .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.9.0"),
    ],
    targets: [
        // The library folder (`Storage`, `K`, `LocalStorage`) and the HTTP server that shares it:
        // used by the app and by the server, which needs none of the app's frameworks.
        .target(
            name: "PapertalkStore",
            path: "Sources/PapertalkStore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `swift run -c release PapertalkServer` (or `app.sh server`): the storage server.
        .executableTarget(
            name: "PapertalkServer",
            dependencies: ["PapertalkStore"],
            path: "Sources/PapertalkServer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Papertalk",
            dependencies: [
                "PapertalkStore",
                .product(name: "FluidAudio", package: "FluidAudio", condition: .when(platforms: [.macOS])),
                .product(name: "OpenCombine", package: "OpenCombine", condition: .when(platforms: [.linux])),
                .product(name: "OpenCombineDispatch", package: "OpenCombine", condition: .when(platforms: [.linux])),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui", condition: .when(platforms: [.linux])),
                .product(name: "GtkBackend", package: "swift-cross-ui", condition: .when(platforms: [.linux])),
            ] + linuxSystemDependencies,
            path: "Sources/Papertalk",
            exclude: ["macOS/Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PapertalkTests",
            dependencies: ["Papertalk", "PapertalkStore"],
            path: "Tests/PapertalkTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ] + linuxSystemTargets
)
