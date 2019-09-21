// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftVideo",
    platforms: [
       .macOS(.v10_14),
       .iOS("11.0.0")
    ],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages
        .library(
            name: "swiftvideo",
            targets:["SwiftVideo"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.2.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.0.0"),
        .package(url: "https://github.com/nicklockwood/VectorMath.git", from: "0.3.3"),
        .package(url: "https://github.com/Thomvis/BrightFutures.git", from: "8.0.1"),
        .package(url: "https://github.com/sunlubo/SwiftFFmpeg", .revision("d20af574b48dfdb66a8bb49861f263d235d60fcf")),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.1.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.1.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .systemLibrary(
            name: "CFreeType",
            path: "Sources/CFreeType",
            pkgConfig: "freetype2",
            providers: [.brew(["freetype2"]), .apt(["libfreetype6-dev"])]
        ),
        .target(name: "CSwiftVideo", dependencies: []),
        .target(
            name: "SwiftVideo",
            dependencies: ["NIO", "CSwiftVideo", "NIOSSL", "NIOExtras", "NIOFoundationCompat","VectorMath", "BrightFutures", 
                            "SwiftFFmpeg", "SwiftProtobuf", "NIOWebSocket", "NIOHTTP1", "CFreeType", "Logging"],
            swiftSettings: [
                .define("GPGPU_OCL", .when(platforms: [.linux, .macOS])),
                .define("GPGPU_METAL", .when(platforms: [.iOS, .tvOS]))
            ]),
        .testTarget(
            name: "swiftVideoTests",
            dependencies: ["SwiftVideo"]),
    ],
    swiftLanguageVersions: [.v5],
    cxxLanguageStandard: .cxx1z
)
