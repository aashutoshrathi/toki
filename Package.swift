// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenBar", targets: ["TokenBar"])
    ],
    targets: [
        .executableTarget(name: "TokenBar")
    ]
)
