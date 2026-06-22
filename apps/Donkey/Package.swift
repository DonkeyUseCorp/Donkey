// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Donkey",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Donkey",
            targets: ["Donkey"]
        ),
        .library(
            name: "DonkeyContracts",
            targets: ["DonkeyContracts"]
        ),
        .library(
            name: "DonkeyHarness",
            targets: ["DonkeyHarness"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .target(
            name: "DonkeyContracts"
        ),
        .target(
            name: "DonkeyHarness",
            dependencies: ["DonkeyContracts"]
        ),
        .target(
            name: "DonkeyRuntime",
            dependencies: [
                "DonkeyContracts",
                "DonkeyHarness"
            ],
            resources: [
                .process("Resources/local-app-finder-profiles.json"),
                .copy("Resources/BuiltInSkills")
            ],
            swiftSettings: [
                .define("DONKEY_DEBUG_OVERLAY", .when(configuration: .debug))
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "DonkeyAI",
            dependencies: [
                "DonkeyContracts",
                "DonkeyRuntime"
            ],
            swiftSettings: [
                .define("DONKEY_DEBUG_OVERLAY", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "DonkeyUI",
            dependencies: ["DonkeyContracts"]
        ),
        .executableTarget(
            name: "Donkey",
            dependencies: [
                "DonkeyAI",
                "DonkeyContracts",
                "DonkeyHarness",
                "DonkeyRuntime",
                "DonkeyUI",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: [
                "Resources/Donkey.icns",
                "Resources/Donkey.iconset"
            ],
            resources: [
                .copy("Resources/donkey-app-icon.png"),
                .copy("Resources/google-continue-dark-rounded.png"),
                .copy("Resources/theme.json")
            ],
            swiftSettings: [
                .define("DONKEY_DEBUG_OVERLAY", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "DonkeyRuntimeTests",
            dependencies: [
                "Donkey",
                "DonkeyAI",
                "DonkeyContracts",
                "DonkeyHarness",
                "DonkeyRuntime",
                "DonkeyUI"
            ],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-L",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
