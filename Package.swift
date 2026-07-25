// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Toki",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Toki", targets: ["Toki"]),
        .executable(name: "TokiWidgets", targets: ["TokiWidgets"])
    ],
    targets: [
        .executableTarget(
            name: "Toki",
            dependencies: ["TokiWidgetShared"],
            resources: [
                .process("Resources")
            ]
        ),
        .target(name: "TokiWidgetShared"),
        .executableTarget(
            name: "TokiWidgets",
            dependencies: ["TokiWidgetShared"],
            swiftSettings: [
                .unsafeFlags(["-application-extension"])
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        ),
        .testTarget(
            name: "TokiTests",
            dependencies: ["Toki", "TokiWidgetShared"],
            resources: [.copy("Fixtures")]
        )
    ]
)
