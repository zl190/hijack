// swift-tools-version:5.9
// The app itself is built by build.sh (swiftc over Sources/). This package exists for the tests:
// `swift test` checks the pure parts of the app, starting with the dictation state machine.
import PackageDescription

let package = Package(
    name: "Hijack",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HijackCore", path: "Sources/Core"),   // pure logic, no AppKit
        .testTarget(name: "HijackCoreTests", dependencies: ["HijackCore"], path: "Tests/HijackCoreTests"),
    ]
)
