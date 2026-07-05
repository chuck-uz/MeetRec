// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetRec",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "MeetRec",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "app/Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
