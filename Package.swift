// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Headroom", targets: ["Headroom"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "CMemory"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "HeadroomCore", dependencies: ["CMemory", "CSQLite"]),
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // The only test target. Swift Testing ships with the toolchain, so every
        // test runs with Command Line Tools alone; there is no XCTest target.
        .testTarget(name: "HeadroomCoreChecks", dependencies: ["HeadroomCore"])
    ]
)
