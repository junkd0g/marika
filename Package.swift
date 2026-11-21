// swift-tools-version: 6.0
import Foundation
import PackageDescription

let storeEdition = ProcessInfo.processInfo.environment["MARIKA_STORE_BUILD"] == "1"
let editionSettings: [SwiftSetting] = storeEdition ? [.define("MARIKA_APP_STORE")] : []
let appDependencies: [Target.Dependency] = ["MarikaCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
    + (storeEdition ? [] : [.product(name: "Sparkle", package: "Sparkle")])

let package = Package(
    name: "Marika",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Marika", targets: ["Marika"]),
        .executable(name: "MarikaBrowserMCP", targets: ["MarikaBrowserMCP"]),
        .library(name: "MarikaCore", targets: ["MarikaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
    ],
    targets: [
        // The engine: agents, protocols, persistence, git. No UI, so it can be tested headless.
        .target(name: "MarikaCore", swiftSettings: editionSettings),
        // The macOS app.
        .executableTarget(name: "Marika", dependencies: appDependencies, swiftSettings: editionSettings,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "MarikaBrowserMCP", dependencies: ["MarikaCore"]),
        .testTarget(
            name: "MarikaCoreTests",
            dependencies: ["MarikaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
