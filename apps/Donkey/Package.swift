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
        .executable(
            name: "DonkeyUIUnderstandingSidecar",
            targets: ["DonkeyUIUnderstandingSidecar"]
        ),
        .library(
            name: "DonkeyContracts",
            targets: ["DonkeyContracts"]
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
            name: "DonkeyRuntime",
            dependencies: ["DonkeyContracts"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "DonkeyAI",
            dependencies: [
                "DonkeyContracts",
                "DonkeyRuntime"
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
                "DonkeyRuntime",
                "DonkeyUI",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .copy("Resources/theme.json")
            ]
        ),
        .executableTarget(
            name: "DonkeyUIUnderstandingSidecar",
            dependencies: [
                "DonkeyRuntime"
            ]
        ),
        .testTarget(
            name: "DonkeyRuntimeTests",
            dependencies: [
                "DonkeyAI",
                "DonkeyContracts",
                "DonkeyRuntime",
                "DonkeyUI"
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
