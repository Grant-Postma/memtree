// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "memtree",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "memtree",
            path: "Sources/memtree"
        ),
        .testTarget(
            name: "memtreeTests",
            dependencies: ["memtree"],
            path: "Tests/memtreeTests"
        ),
    ]
)
