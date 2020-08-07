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

#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import VideoToolbox
import Dispatch

enum DecodeError: Error {
    case invalidBase
    case osstatus(Int32)
    case unsupportedCodec
}

public class AppleVideoDecoder: Tx<CodedMediaSample, PictureSample> {

    public init(_ clock: Clock) {
        self.session = nil
        self.output =  [PictureSample]()
        self.clock = clock
        let uuid = UUID().uuidString
        self.sampleQueue = DispatchQueue(label: "apple.decode.samples.\(uuid)")
        self.decodeQueue = DispatchQueue(label: "apple.decode.\(uuid)")
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            guard [.avc, .hevc, .vp9].contains(sample.mediaFormat()) else {
                return .error(EventError("dec.video.apple",
                   -1,
                   "\(sample.mediaFormat()) not supported. AppleVideoDecoder only supports AVC and HEVC"))
            }
            if strongSelf.session == nil {
                do {
                    try strongSelf.setupSession(sample)
                } catch {
                    print("caught error \(error)")
                    return .error(EventError("dec.video.apple", -5, "Error making decode session \(error)"))
                }
            }

            return strongSelf.decodeQueue.sync { strongSelf.handle(sample) }
        }
    }
    deinit {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
    }
    private func handle(_ sample: CodedMediaSample) -> EventBox<PictureSample> {
        guard let session = self.session else {
            return .error(EventError("dec.video.apple", -2, "No decode session"))
        }
        var payload = sample.data()

        let dataBufferWk: CMBlockBuffer? = payload.withUnsafeMutableBytes {
            var buffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                               memoryBlock: $0.baseAddress,
                                               blockLength: $0.count,
                                               blockAllocator: kCFAllocatorNull,
                                               customBlockSource: nil,
                                               offsetToData: 0,
                                               dataLength: $0.count,
                                               flags: 0,
                                               blockBufferOut: &buffer)
            return buffer
        }
        guard let dataBuffer = dataBufferWk else {
            print("Failed to create buffer")
            return .error(EventError("dec.video.apple", -2, "Failed to create buffer"))
        }
        let pts = rescale(sample.pts(), 90000).value
        let dts = rescale(sample.dts(), 90000).value
        var videoSampleTimingInfo = CMSampleTimingInfo(duration: CMTimeMake(value: 1, timescale: 1),
                                       presentationTimeStamp: CMTimeMake(value: pts, timescale: 90000),
                                       decodeTimeStamp: CMTimeMake(value: dts, timescale: 90000))
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = [sample.data().count]
        CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                             dataBuffer: dataBuffer,
                             dataReady: true,
                             makeDataReadyCallback: nil,
                             refcon: nil,
                             formatDescription: formatDesc,
                             sampleCount: 1,
                             sampleTimingEntryCount: 1,
                             sampleTimingArray: &videoSampleTimingInfo,
                             sampleSizeEntryCount: 1,
                             sampleSizeArray: &sampleSize,
                             sampleBufferOut: &sampleBuffer)
        if let sampleBuffer = sampleBuffer {
            let flags: VTDecodeFrameFlags = [._1xRealTimePlayback,
                                             ._EnableTemporalProcessing,
                                             ._EnableAsynchronousDecompression]
            let result = VTDecompressionSessionDecodeFrame(session,
                                              sampleBuffer: sampleBuffer,
                                              flags: flags,
                                              infoFlagsOut: nil) { [weak self] (_, _, imgBuffer, pts, _) in
                                                guard let strongSelf = self, let imgBuffer = imgBuffer else {
                                                    return
                                                }
                                                let ptsTime = TimePoint(pts.value, Int64(pts.timescale))
                                                let img = ImageBuffer(imgBuffer)
                                                let pic = PictureSample(img,
                                                                        assetId: sample.assetId(),
                                                                        workspaceId: sample.workspaceId(),
                                                                        time: strongSelf.clock.current(),
                                                                        pts: ptsTime)
                                                strongSelf.sampleQueue.sync {
                                                    strongSelf.output.append(pic)
                                                    strongSelf.output = strongSelf
                                                        .output.sorted { $0.pts() < $1.pts() }
                                                }
                }
            if result != 0 {
                print("result=\(result)")
                return .error(EventError("dec.video.apple", Int(result), "OSStatus, decode failed"))
            }
        }
        return self.sampleQueue.sync {
            if let outSample = self.output[safe:0], self.output.count >= 5 {
                self.output.removeFirst()
                return .just(outSample)
            } else {
                return .nothing(sample.info())
            }
        }
    }
    private func setupSession(_ sample: CodedMediaSample) throws {
        let desc = try basicMediaDescription(sample)
        guard case .video(let videoDesc) = desc else {
            return
        }
        let pixelBufferOptions =
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelBufferWidthKey as String: Int(videoDesc.size.x),
             kCVPixelBufferHeightKey as String: Int(videoDesc.size.y)] as CFDictionary
        formatDesc = try videoFormatDescription(sample)

        if let format = formatDesc {
            var session: VTDecompressionSession?
            let decoderSpecification = [:] as CFDictionary
            let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                          formatDescription: format,
                                          decoderSpecification: decoderSpecification,
                                          imageBufferAttributes: pixelBufferOptions,
                                          outputCallback: nil,
                                          decompressionSessionOut: &session)
            if result != 0 {
                throw DecodeError.osstatus(result)
            }
            self.session = session
        }

    }
    private var output: [PictureSample]
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private let clock: Clock
    private let sampleQueue: DispatchQueue
    private let decodeQueue: DispatchQueue
}

private func videoFormatDescription(_ sample: CodedMediaSample) throws -> CMVideoFormatDescription? {
    switch(sample.mediaFormat()) {
    case .avc:
        guard let dcr = sample.sideData()["config"] else {
            throw MediaDescriptionError.invalidMetadata
        }
        let paramSets = parameterSetsFromAVCC(dcr)
        return try videoFormatFromAVCParameterSets(paramSets)
    case .vp9:
        return try videoFormatFromVP9(sample)
    default:
        throw DecodeError.unsupportedCodec
    }
}

private func videoFormatFromVP9(_ sample: CodedMediaSample) throws -> CMVideoFormatDescription? {
    let desc = try basicMediaDescription(sample)
    guard case .video(let videoDesc) = desc else {
        return nil
    }
    var formatDesc: CMVideoFormatDescription?
    let extensions = [
        kCMFormatDescriptionExtension_FullRangeVideo as String: videoDesc.fullRangeColor
    ] as CFDictionary
    _ = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
          codecType: kCMVideoCodecType_VP9,
          width: Int32(videoDesc.size.x),
          height: Int32(videoDesc.size.y),
          extensions: extensions,
          formatDescriptionOut: &formatDesc)
    return formatDesc
}

private func videoFormatFromAVCParameterSets( _ paramSets: [[UInt8]]) throws -> CMVideoFormatDescription? {
    let pmSetPtrs: [UnsafePointer<UInt8>] = try paramSets.map {
        try $0.withUnsafeBufferPointer {
            guard let baseAddress = $0.baseAddress else {
                throw DecodeError.invalidBase
            }
            return baseAddress
        }
    }
    let sizes = paramSets.map { $0.count }
    var formatDesc: CMVideoFormatDescription?
    try sizes.withUnsafeBufferPointer { sizePtr in
        try pmSetPtrs.withUnsafeBufferPointer { pmPtrPtr in
            guard let pmBase = pmPtrPtr.baseAddress, let sizeBase = sizePtr.baseAddress else {
                throw DecodeError.invalidBase
            }
            _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                                parameterSetCount: paramSets.count,
                                                                parameterSetPointers: pmBase,
                                                                parameterSetSizes: sizeBase,
                                                                nalUnitHeaderLength: 4,
                                                                formatDescriptionOut: &formatDesc)
        }
    }
    return formatDesc
}

private func parameterSetsFromAVCC(_ avcc: Data) -> [[UInt8]] {
    var buf = buffer.fromData(avcc)
    var paramSets = [[UInt8]]()
    buf.moveReaderIndex(forwardBy: 5) // skip header
    guard let spsCountBytes = buf.readBytes(length: 1) else {
        return []
    }
    let spsCount = (spsCountBytes[0] & 0x1F)
    for _ in 0..<spsCount {
        guard let spsSize = buf.readInteger(endianness: .big, as: Int16.self),
              let spsBytes = buf.readBytes(length: Int(spsSize)) else {
            return []
        }
        paramSets.append(spsBytes)
    }
    guard let ppsCount = buf.readBytes(length: 1) else {
        return []
    }
    for _ in 0..<ppsCount[0] {
        guard let ppsSize = buf.readInteger(endianness: .big, as: Int16.self),
              let ppsBytes = buf.readBytes(length: Int(ppsSize)) else {
            return []
        }
        paramSets.append( ppsBytes)
    }
    return paramSets
}

#endif
