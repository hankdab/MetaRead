// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NovelReaderApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NovelReaderApp", targets: ["NovelReaderApp"])
    ],
    targets: [
        .executableTarget(
            name: "NovelReaderApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "NovelReaderAppTests",
            dependencies: ["NovelReaderApp"]
        )
    ]
)
