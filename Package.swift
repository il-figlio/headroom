// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Headboard",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Headboard", targets: ["Headboard"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "CMemory"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "HeadboardCore", dependencies: ["CMemory", "CSQLite"]),
        .executableTarget(name: "Headboard", dependencies: ["HeadboardCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // Swift Testing ships with the toolchain, so these run with Command Line Tools alone.
        .testTarget(name: "HeadboardCoreChecks", dependencies: ["HeadboardCore"])
    ]
)

// XCTest needs full Xcode. `HEADBOARD_SKIP_XCTEST=1` (set by scripts/check.sh) builds
// without it so the Swift Testing checks still run on a Command Line Tools-only Mac.
if Context.environment["HEADBOARD_SKIP_XCTEST"] == nil {
    package.targets.append(.testTarget(name: "HeadboardCoreTests", dependencies: ["HeadboardCore"]))
}
