// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Toki",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Toki", targets: ["Toki"])
    ],
    targets: [
        .executableTarget(
            name: "Toki",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TokiTests",
            dependencies: ["Toki"],
            resources: [.copy("Fixtures")]
        )
    ]
)
