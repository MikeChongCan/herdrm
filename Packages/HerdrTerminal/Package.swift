// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrTerminal",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(name: "HerdrTerminal", targets: ["HerdrTerminal"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            path: "Artifacts/ghostty-vt.xcframework"
        ),
        .target(
            name: "HerdrTerminal",
            dependencies: ["GhosttyVt"],
            cSettings: [
                .define("GHOSTTY_STATIC"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-DGHOSTTY_STATIC"]),
            ]
        ),
    ]
)
