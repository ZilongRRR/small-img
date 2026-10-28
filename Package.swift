// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SmallImg",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SmallImg",
            path: "Sources/SmallImg",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
