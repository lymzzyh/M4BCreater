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
            exclude: [
                "Resources/AppIcon.icns",
                "Resources/AppIcon.iconset",
                "Resources/AppIcon.png",
                "Resources/FFmpeg/ffmpeg-arm64",
                "Resources/FFmpeg/ffmpeg-x86_64",
                "Resources/FFmpeg/ffprobe-arm64",
                "Resources/FFmpeg/ffprobe-x86_64"
            ],
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
