## SwiftVideo

[![GitHub Actions](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Factions-badge.atrox.dev%2Funpause-live%2FSwiftVideo%2Fbadge&label=build&logo=none)](https://actions-badge.atrox.dev/unpause-live/SwiftVideo/goto)

Video streaming and processing framework for Linux, macOS, and iOS/iPadOS (maybe even tvOS).  Swift 5.1+ because I'm just opening this up and I really don't feel like dealing with older versions of Swift.

This is very much a WIP.  Support is currently better for Linux than macOS and even less-so for iOS devices.  Work needs to be done on the Podfile for better Xcode interop (swift package manager doesn't do such a great job there).


### Getting Started

For now, check the Examples directory for some hints about how to use this framework.  I promise I will be creating
documentation to clarify how it all fits together and how you can do useful, interesting things with this framework.

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