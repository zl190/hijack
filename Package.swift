// swift-tools-version:5.9
// One package, two targets: HijackCore (pure logic, no AppKit, what `swift test` checks) and the Hijack app.
// build.sh runs `swift build -c release --product Hijack`, then assembles the bundle, embeds Sparkle and signs.
// Sparkle comes from .sparkle/<version>/ (build.sh downloads it, pinned by sha256) and is linked here.
import PackageDescription

let sparkleDir = Context.packageDirectory + "/.sparkle/2.10.0"  // keep in step with SPARKLE_VERSION in scripts/fetch-sparkle.sh

let package = Package(
    name: "Hijack",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HijackCore", path: "Sources/Core"),
        .executableTarget(
            name: "Hijack",
            dependencies: ["HijackCore"],
            path: "Sources/App",
            swiftSettings: [.unsafeFlags(["-F", sparkleDir])],
            // `import Sparkle` autolinks the framework; the linker needs the search path and the rpath only.
            linkerSettings: [
                .unsafeFlags(["-F", sparkleDir, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]),
        .testTarget(name: "HijackCoreTests", dependencies: ["HijackCore"], path: "Tests/HijackCoreTests"),
    ]
)
