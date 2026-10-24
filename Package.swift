// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Insomnia",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        // Over-the-air updates: an appcast on the fork's GitHub Releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Insomnia",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Insomnia",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                // Sparkle.framework ships in the bundle's Frameworks folder.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Test-only C target. Its constructor points INSOMNIA_HOME at a temp
        // directory when the test bundle loads, before any test can log.
        .target(
            name: "InsomniaTestHome",
            path: "Tests/InsomniaTestHome"
        ),
        .testTarget(
            name: "InsomniaTests",
            dependencies: ["Insomnia", "InsomniaTestHome"],
            path: "Tests/InsomniaTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
