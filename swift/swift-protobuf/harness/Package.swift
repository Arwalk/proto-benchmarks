// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "proto-bench-swift-protobuf",
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .executableTarget(
            name: "bench",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            path: "Sources/bench"
        ),
    ]
)
