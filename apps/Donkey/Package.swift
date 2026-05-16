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
        )
    ],
    targets: [
        .target(
            name: "DonkeyContracts"
        ),
        .target(
            name: "DonkeyRuntime",
            dependencies: ["DonkeyContracts"]
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
                "DonkeyUI"
            ],
            resources: [
                .copy("Resources/theme.json")
            ]
        ),
        .testTarget(
            name: "DonkeyRuntimeTests",
            dependencies: [
                "DonkeyAI",
                "DonkeyContracts",
                "DonkeyRuntime"
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
