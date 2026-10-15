// swift-tools-version:6.0
// Spike S2 (docs/LINUX_PORT.md): Swift driving python/papertalk_platform through PythonKit.
import PackageDescription

let package = Package(
    name: "PythonSpike",
    dependencies: [.package(url: "https://github.com/pvieito/PythonKit", revision: "e1d34f95c58189b771bfc8423b9b2cf8fc651664")],
    targets: [
        .executableTarget(name: "PythonSpike", dependencies: [.product(name: "PythonKit", package: "PythonKit")],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
