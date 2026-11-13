// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NidgeKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NidgeKit", targets: ["NidgeKit"]),
        .library(name: "NidgeMock", targets: ["NidgeMock"]),
    ],
    targets: [
        .target(name: "NidgeKit"),
        // In-process PTP/IP camera for tests and for `nidge-cli mock`.
        .target(name: "NidgeMock", dependencies: ["NidgeKit"]),
        .testTarget(name: "NidgeKitTests", dependencies: ["NidgeKit", "NidgeMock"]),
    ]
)
