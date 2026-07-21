// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "strip102",
    traits: [
        .trait(
            name: "PixelF32",
            description: """
                Store canvas pixels as premultiplied float (SIMD4<Float>) instead of \
                premultiplied RGBA8. Blending never converts and values stay unclamped through \
                compositing, at four times the bytes per pixel — which costs more than the \
                conversions save once the canvas stops fitting in cache.
                """
        ),
        // .default(enabledTraits: ["PixelF32"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(name: "Cnanosvg"),
        .target(name: "Cstb"),

        .executableTarget(
            name: "strip102",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "Cnanosvg",
                "Cstb",
            ]
        ),
        .testTarget(
            name: "strip102Tests",
            dependencies: ["strip102"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
