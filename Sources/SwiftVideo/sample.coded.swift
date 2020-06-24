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

import NIO
import NIOFoundationCompat
import Foundation
import VectorMath
import CSwiftVideo

public enum EncodeError: Error {
    case invalidMediaFormat
    case invalidPixelFormat
    case invalidImageBuffer
    case invalidContext
    case encoderNotFound
}

public struct AVCSettings {
    public let useBFrames: Bool
    public let useHWAccel: Bool
    public let profile: String
    public let preset: String
    public init(useBFrames: Bool? = nil,
                useHWAccel: Bool? = nil,
                profile: String? = nil,
                preset: String? = nil) {
        self.useBFrames = useBFrames ?? false
        self.useHWAccel = useHWAccel ?? false
        self.profile = profile ?? "main"
        self.preset = preset ?? "veryfast"
    }
}

public enum EncoderSpecificSettings {
    case avc(AVCSettings)
    case unused
}

public struct BasicVideoDescription {
    public let size: Vector2
}

public struct BasicAudioDescription {
    public let sampleRate: Float
    public let channelCount: Int
    public let samplesPerPacket: Int
}

public enum BasicMediaDescription {
    case video(BasicVideoDescription)
    case audio(BasicAudioDescription)
}

public func formatsFilter (_ formats: [MediaFormat]) -> Tx<CodedMediaSample, CodedMediaSample> {
    return Tx { sample in
        if formats.contains(where: { sample.mediaFormat() == $0 }) {
            return .just(sample)
        } else {
            return .nothing(sample.info())
        }
    }
}

public func mediaTypeFilter(_ mediaType: MediaType) -> Tx<CodedMediaSample, CodedMediaSample> {
    return Tx { sample in
        if sample.mediaType() == mediaType {
            return .just(sample)
        } else {
            return .nothing(sample.info())
        }
    }
}

public struct CodedMediaSample {
    let eventInfo: EventInfo?
    var wire: CodedMediaSampleWire
}

//
//
// See Proto/CodedMediaSample.proto
extension CodedMediaSample: Event {
    public func type() -> String {
        return "sample.mediacoded"
    }

    public func time() -> TimePoint {
        return wire.eventTime
    }

    public func assetId() -> String {
        return wire.idAsset
    }

    public func workspaceId() -> String {
        return wire.idWorkspace
    }

    public func workspaceToken() -> String? {
        return wire.tokenWorkspace
    }

    public func mediaType() -> MediaType {
        return wire.mediatype
    }

    public func mediaFormat() -> MediaFormat {
        return wire.mediaformat
    }

    public func info() -> EventInfo? {
        return eventInfo
    }

    public func pts() -> TimePoint {
        return wire.pts
    }

    public func dts() -> TimePoint {
        return wire.dts
    }

    public func serializedData() throws -> Data {
        return try wire.serializedData()
    }

    public func data() -> Data {
        return wire.buffer
    }

    public func sideData() -> [String: Data] {
        return wire.side
    }

    public func constituents() -> [MediaConstituent]? {
        return  wire.constituents
    }

    public init(_ assetId: String,
                _ workspaceId: String,
                _ time: TimePoint,
                _ pts: TimePoint,
                _ dts: TimePoint?,
                _ type: MediaType,
                _ format: MediaFormat,
                _ data: Data,
                _ sideData: [String: Data]?,
                _ encoder: String?,
                workspaceToken: String? = nil,
                eventInfo: EventInfo? = nil,
                constituents: [MediaConstituent] = [MediaConstituent]()) {
        self.wire = CodedMediaSampleWire()
        self.wire.mediatype = type
        self.wire.mediaformat = format
        self.wire.buffer = data
        self.wire.eventTime = time
        self.wire.pts = pts
        self.wire.dts = dts ?? pts
        self.wire.side = sideData ?? [String: Data]()
        self.wire.idAsset = assetId
        self.wire.idWorkspace = workspaceId
        self.wire.tokenWorkspace = workspaceToken ?? ""
        self.wire.encoder = encoder ?? ""
        self.eventInfo = eventInfo
        self.wire.constituents = constituents
    }

    public init(_ other: CodedMediaSample,
                assetId: String? = nil,
                constituents: [MediaConstituent]? = nil,
                eventInfo: EventInfo? = nil) {
        self.wire = other.wire
        self.wire.idAsset = assetId ?? other.assetId()
        self.eventInfo = eventInfo ?? other.eventInfo
        self.wire.constituents = constituents ?? other.wire.constituents
    }

    public init(serializedData: Data, eventInfo: EventInfo? = nil) throws {
        self.wire = try CodedMediaSampleWire(serializedData: serializedData)
        self.eventInfo = eventInfo
    }
}

enum MediaDescriptionError: Error {
    case unsupported
    case invalidMetadata
}

func basicMediaDescription(_ sample: CodedMediaSample) throws -> BasicMediaDescription {
    switch sample.mediaFormat() {
    case .avc:
        let sps = try spsFromAVCDCR(sample)
        let (width, height): (Int32, Int32) = sps.withUnsafeBytes {
            var width: Int32 = 0
            var height: Int32 = 0
            h264_sps_frame_size($0.baseAddress, Int64($0.count), &width, &height)
            return (width, height)
        }
        return .video(BasicVideoDescription(size: Vector2(Float(width), Float(height))))
    case .aac:
        guard let asc = sample.sideData()["config"] else {
            throw MediaDescriptionError.invalidMetadata
        }
        let (channels, sampleRate, samplesPerPacket): (Int32, Int32, Int32) = asc.withUnsafeBytes {
            var channels: Int32 = 0
            var sampleRate: Int32 = 0
            var samplesPerPacket: Int32 = 0
            aac_parse_asc($0.baseAddress, Int64($0.count), &channels, &sampleRate, &samplesPerPacket)
            return (channels, sampleRate, samplesPerPacket)
        }
        return .audio(BasicAudioDescription(sampleRate: Float(sampleRate),
                                            channelCount: Int(channels),
                                            samplesPerPacket: Int(samplesPerPacket)))
    default:
        throw MediaDescriptionError.unsupported
    }
}

public func isKeyframe(_ sample: CodedMediaSample) -> Bool {
    guard sample.mediaType() == .video else {
        return true
    }
    switch sample.mediaFormat() {
    case .avc:
        return isKeyframeAVC(sample)
    case .hevc:
        return false
    default:
        return false
    }
}

// TODO: Add HEVC, VP8/VP9, AV1
private func isKeyframeAVC(_ sample: CodedMediaSample) -> Bool {
    guard sample.data().count >= 5 else {
        return false
    }
    return sample.data()[4] & 0x1f == 5
}

private func spsFromAVCDCR(_ sample: CodedMediaSample) throws -> Data {
    guard let record = sample.sideData()["config"],
          record.count > 8 else {
        throw MediaDescriptionError.invalidMetadata
    }
    //let spsCount = Int(record[5]) & 0x1f
    let size = (Int(record[6]) << 8) | Int(record[7])
    guard record.count > 8 + size else {
        throw MediaDescriptionError.invalidMetadata
    }
    return record[8..<8+size]
}
