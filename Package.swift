// swift-tools-version:5.2
/*
   SwiftVideo, Copyright 2019 Unpause SAS

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

import PackageDescription
import Foundation

let cudaVer = ProcessInfo.processInfo.environment["CUDA_VER"]

let cudaTarget: [Target] = cudaVer.map { ver in
    [.systemLibrary(
      name: "CCUDA",
      path: "Sources/CCUDA",
      pkgConfig: "cuda-\(ver)")]
  } ?? []

let dependencies: [Target.Dependency] = cudaVer != nil ? ["CCUDA"] : []

let swiftSettings: [SwiftSetting] = (cudaVer != nil ? [.define("GPGPU_CUDA", .when(platforms: [.linux]))] :
    [.define("GPGPU_OCL", .when(platforms: [.macOS, .linux]))]) +
    [.define("GPGPU_METAL", .when(platforms: [.iOS, .tvOS]))]

let cSettings: [CSetting] = (cudaVer == nil ? [.define("CL_USE_DEPRECATED_OPENCL_1_2_APIS"),
                .define("GPGPU_OCL", .when(platforms: [.macOS, .linux]))] : []) +
                [.define("linux", .when(platforms: [.linux]))]

let linkerSettings: [LinkerSetting] = (cudaVer == nil ? [.linkedLibrary("OpenCL", .when(platforms: [.linux]))] :
    [.linkedLibrary("nvrtc", .when(platforms: [.linux]))]) +
    [.linkedLibrary("bsd", .when(platforms: [.linux]))]

let package = Package(
    name: "SwiftVideo",
    platforms: [
       .macOS(.v10_14),
       .iOS("13.1")
    ],
    products: [
      .library(
          name: "SwiftVideo",
          targets:["SwiftVideo", "SwiftVideo_FFmpeg", "SwiftVideo_Freetype"]),
      .library(
            name: "SwiftVideo_Bare",
            targets: ["SwiftVideo"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.9.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.3.1"),
        .package(url: "https://github.com/nicklockwood/VectorMath.git", from: "0.4.0"),
        .package(url: "https://github.com/Thomvis/BrightFutures.git", from: "8.0.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.4.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.1.1"),
        .package(url: "https://github.com/sunlubo/SwiftFFmpeg", .revision("22b886fd5242c1923f0993c9541768a9a16e33f2"))
    ],
    targets: [
        .systemLibrary(
            name: "CFreeType",
            path: "Sources/CFreeType",
            pkgConfig: "freetype2",
            providers: [.brew(["freetype2"]), .apt(["libfreetype6-dev"])]
        ),
        .target(name: "CSwiftVideo",
            dependencies: [],
            cSettings: [
              .define("linux", .when(platforms: [.linux]))],
            cxxSettings: [
              .define("linux", .when(platforms: [.linux]))]
        ),
        .target(
            name: "SwiftVideo",
            dependencies: [.product(name: "NIO", package: "swift-nio"),
                "CSwiftVideo",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "NIOFoundationCompat", package: "swift-nio-extras"),
                "VectorMath",
                "BrightFutures",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")] + dependencies,
            cSettings: cSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        ),
        .target(
            name: "SwiftVideo_FFmpeg",
            dependencies: ["SwiftVideo", "SwiftFFmpeg"],
            cSettings: [
                .define("linux", .when(platforms: [.linux])),
                .define("USE_FFMPEG")
            ],
            swiftSettings: [
                .define("USE_FFMPEG")
            ]
        ),
        .target(
            name: "SwiftVideo_Freetype",
            dependencies: ["SwiftVideo", "CFreeType"],
            cSettings: [
                .define("linux", .when(platforms: [.linux])),
                .define("USE_FREETYPE")
            ],
            swiftSettings: [
                .define("USE_FREETYPE")
            ]
        ),
        .testTarget(
            name: "swiftVideoTests",
            dependencies: ["SwiftVideo", "CSwiftVideo", "SwiftVideo_FFmpeg"]),
        .testTarget(
            name: "swiftVideoInternalTests",
            dependencies: ["SwiftVideo", "CSwiftVideo"],
            swiftSettings: [
              .define("DISABLE_INTERNAL", .when(configuration: .release))
            ])
    ],
    swiftLanguageVersions: [.v5],
    cxxLanguageStandard: .cxx1z
) /* package */
