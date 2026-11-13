// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nidge-cli",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/NidgeKit")],
    targets: [
        .executableTarget(name: "nidge-cli", dependencies: [
            .product(name: "NidgeKit", package: "NidgeKit"),
            .product(name: "NidgeMock", package: "NidgeKit"),
        ]),
    ]
)
