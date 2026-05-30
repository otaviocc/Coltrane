// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Coltrane",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Coltrane", targets: ["Coltrane"]),
        .executable(name: "FiboDemo", targets: ["FiboDemo"]),
        .executable(name: "MandelbrotDemo", targets: ["MandelbrotDemo"]),
        .executable(name: "NBodyDemo", targets: ["NBodyDemo"]),
        .executable(name: "NBody3DDemo", targets: ["NBody3DDemo"])
    ],
    targets: [
        .target(name: "Coltrane"),
        .executableTarget(
            name: "FiboDemo",
            dependencies: ["Coltrane"]
        ),
        .executableTarget(
            name: "MandelbrotDemo",
            dependencies: ["Coltrane"]
        ),
        .executableTarget(
            name: "NBodyDemo",
            dependencies: ["Coltrane"]
        ),
        .executableTarget(
            name: "NBody3DDemo",
            dependencies: ["Coltrane"]
        ),
        .testTarget(
            name: "ColtraneTests",
            dependencies: ["Coltrane"]
        )
    ]
)
