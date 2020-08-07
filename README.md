## SwiftVideo

[![GitHub Actions](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Factions-badge.atrox.dev%2Funpause-live%2FSwiftVideo%2Fbadge&label=build&logo=none)](https://actions-badge.atrox.dev/unpause-live/SwiftVideo/goto)
![Swift version](https://img.shields.io/badge/swift-5-orange.svg)
![License](https://img.shields.io/github/license/unpause-live/SwiftVideo)


Video streaming and processing framework for Linux, macOS, and iOS/iPadOS/tvOS.  Swift 5.1+ because I'm just opening this up and I really don't feel like dealing with older versions of Swift.

### Getting Started

For now, check the Examples directory for some hints about how to use this framework. I promise I will be creating
documentation to clarify how it all fits together and how you can do useful, interesting things with this framework.


#### Using with SwiftPM

1. Add `.package(url: "https://github.com/unpause-live/SwiftVideo.git", from: "0.2.0")` to your package dependencies
2. In your target dependencies, add either `SwiftVideo` or `SwiftVideo_Bare` depending on whether or not you wish to
build with FFmpeg and Freetype support.

#### Using with Xcode + iOS

You can use this project in Xcode for iOS as a Swift Package as of 0.2.0.

1. Go to File -> Swift Packages -> Add Package Dependency, or in your Project settings go to the Swift Packages tab and press +
2. Set the package repository URL to https://github.com/unpause-live/SwiftVideo 
3. Select the branch or version you want to reference. Only 0.2.0 and above will be usable on iOS unless you also compile
FFmpeg and Freetype for it.
4. Choose the `SwiftVideo_Bare` product when prompted. This will build SwiftVideo without FFmpeg and Freetype. If you have built
those libraries for iOS and wish to use them with SwiftVideo, choose the `SwiftVideo` product instead.
5. If you are using the VideoMixer you will need to include `Sources/SwiftVideo/kernels.metal` in your project directly so that they are included. This will be changed [when Swift 5.3 is released](https://github.com/apple/swift-evolution/blob/master/proposals/0278-package-manager-localized-resources.md).

### Current Features

- RTMP Client and Server
- "Flavor" Client and Server (toy protocol, see flavor.md)
- OpenCL Support
- Metal Support
- Audio Decode/Encode (via FFmpeg and CoreAudio)
- Video Decode/Encode (via FFmpeg and CoreVideo)
- Camera capture (macOS/iOS)
- Text rendering (via FreeType)
- Video Mixer
- Audio Mixer
- Audio Resampler (via FFmpeg+SOX)


FFmpeg support is thanks to https://github.com/sunlubo/SwiftFFmpeg
