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
        .executable(name: "NBody3DDemo", targets: ["NBody3DDemo"]),
        .executable(name: "MergeSortDemo", targets: ["MergeSortDemo"]),
        .executable(name: "NQueensDemo", targets: ["NQueensDemo"]),
        .executable(name: "MonteCarloPiDemo", targets: ["MonteCarloPiDemo"]),
        .executable(name: "ReactionDiffusionDemo", targets: ["ReactionDiffusionDemo"]),
        .executable(name: "BlackScholesDemo", targets: ["BlackScholesDemo"]),
        .executable(name: "GameOfLifeDemo", targets: ["GameOfLifeDemo"]),
        .executable(name: "RayTracerDemo", targets: ["RayTracerDemo"])
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
        .executableTarget(
            name: "MergeSortDemo",
            dependencies: ["Coltrane"]
        ),
        .executableTarget(
            name: "NQueensDemo",
            dependencies: ["Coltrane"]
        ),
        .executableTarget(
            name: "MonteCarloPiDemo",
            dependencies: ["Coltrane"]
        ),
        .executableTarget(
            name: "ReactionDiffusionDemo",
            dependencies: ["Coltrane"]
        ),
        .executableTarget(
            name: "BlackScholesDemo",
            dependencies: ["Coltrane"]
        ),
        .executableTarget(
            name: "GameOfLifeDemo",
            dependencies: ["Coltrane"]
        ),
        .executableTarget(
            name: "RayTracerDemo",
            dependencies: ["Coltrane"]
        ),
        .testTarget(
            name: "ColtraneTests",
            dependencies: ["Coltrane"]
        )
    ]
)
