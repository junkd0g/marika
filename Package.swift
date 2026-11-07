// swift-tools-version: 6.0
import PackageDescription

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
        .target(name: "MarikaCore"),
        // The macOS app.
        .executableTarget(name: "Marika", dependencies: ["MarikaCore", .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "MarikaBrowserMCP", dependencies: ["MarikaCore"]),
        .testTarget(
            name: "MarikaCoreTests",
            dependencies: ["MarikaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
