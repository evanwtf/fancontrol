// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fancontrol",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "fancontrol", targets: ["fancontrol"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "fancontrol",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "fancontrolTests",
            dependencies: ["fancontrol"]
        )
    ]
)
