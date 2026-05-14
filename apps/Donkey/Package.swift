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
            dependencies: ["DonkeyContracts"]
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
            ]
        )
    ]
)
