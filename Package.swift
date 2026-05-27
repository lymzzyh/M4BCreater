// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "M4BCreater",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "M4BCreater", targets: ["M4BCreater"])
    ],
    targets: [
        .executableTarget(
            name: "M4BCreater",
            path: "Sources/M4BCreater",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "M4BCreaterTests",
            dependencies: ["M4BCreater"],
            path: "Tests/M4BCreaterTests"
        )
    ]
)
