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
import VideoToolbox
import Dispatch

public class AppleVideoEncoder: Tx<PictureSample, [CodedMediaSample]> {

    enum AppleVideoEncoderError: Error {
        case noSession
        case invalidSystemVersion
    }

    public init(format: MediaFormat, frame: CGSize, bitrate: Int = 500000) {
        //assert(format == .avc || format == .hevc, "AppleVideoEncoder only supports AVC and HEVC")
        self.queue = DispatchQueue.init(label: "cezium.encode.video")
        let codecType = { () -> CMVideoCodecType in
            switch format {
                case .avc:
                    return kCMVideoCodecType_H264
                case .hevc:
                    return kCMVideoCodecType_HEVC
                case .vp9:
                    return kCMVideoCodecType_VP9
                default:
                    return kCMVideoCodecType_H264
            }
        }()
        let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
           width: Int32(frame.width),
           height: Int32(frame.height),
           codecType: codecType,
           encoderSpecification: [kVTCompressionPropertyKey_ExpectedFrameRate: 30] as CFDictionary,
           imageBufferAttributes: pixelBufferOptions(frame),
           compressedDataAllocator: nil,
           outputCallback: nil,
           refcon: nil,
           compressionSessionOut: &self.session)
        self.format = format
        super.init()
        super.set {
            [weak self] in
            if let strongSelf = self {
                do {
                    try strongSelf.setBitrate(bitrate)
                    try strongSelf.enc($0)
                } catch AppleVideoEncoderError.invalidSystemVersion {
                    return .error(EventError("venc", -1, "Invalid System Version", $0.time()))
                } catch AppleVideoEncoderError.noSession {
                    return .error(EventError("venc", -2, "No Media Session", $0.time()))
                } catch {
                    return .error(EventError("venc", -999, "Unexpected Error \(error)", $0.time()))
                }
                let res = strongSelf.samples
                strongSelf.samples.removeAll()
                return res.count > 0 ? .just(res) : .nothing($0.info())
            }
            return .error(EventError("venc", -1000, "Encoder has gone away"))
        }
    }

    func setBitrate(_ bitrate: Int) throws {
        guard let session = self.session else {
            throw AppleVideoEncoderError.noSession
        }
        let val = bitrate as CFTypeRef
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: val)
    }

    func enc(_ sample: PictureSample) throws {
        guard let image = sample.imageBuffer() else {
            return
        }
        guard let session = self.session else {
            throw AppleVideoEncoderError.noSession
        }
        let sampleTime = sample.time()
        let assetId = sample.assetId()
        let workspaceId = sample.workspaceId()
        let workspaceToken = sample.workspaceToken()
        let outputHandler: VTCompressionOutputHandler = { [weak self] (status, flags, sample) in
            if let strongSelf = self, let smp = sample {
                if let buf = CMSampleBufferGetDataBuffer(smp) {
                    var size: Int = 0
                    var data: UnsafeMutablePointer<Int8>?

                    CMBlockBufferGetDataPointer(buf,
                                                atOffset: 0,
                                                lengthAtOffsetOut: nil,
                                                totalLengthOut: &size,
                                                dataPointerOut: &data)

                    if size > 0 {
                        let bytebuf = Data(buffer: UnsafeBufferPointer(start: data, count: size))
                        let pts = CMSampleBufferGetPresentationTimeStamp(smp)
                        let dts = CMSampleBufferGetDecodeTimeStamp(smp)
                        let fmt = CMSampleBufferGetFormatDescription(smp)
                        var extradata: Data?
                        if let fmt = fmt,
                            let extensions = CMFormatDescriptionGetExtensions(fmt) as? [String: AnyObject],
                            let sampleDesc = extensions["SampleDescriptionExtensionAtoms"] {
                            switch strongSelf.format {
                            case .avc:
                                if let opt = sampleDesc["avcC"], let desc = opt { extradata = desc as? Data }
                            case .hevc:
                                if let opt = sampleDesc["hvcC"], let desc = opt { extradata = desc as? Data }
                            default: ()
                            }
                        }
                        let samp = CodedMediaSample(assetId,
                                                    workspaceId,
                                                    sampleTime,
                                                    TimePoint(pts.value, Int64(pts.timescale)),
                                                    dts == .invalid ? nil : TimePoint(dts.value, Int64(dts.timescale)),
                                                    .video,
                                                    strongSelf.format,
                                                    bytebuf,
                                                    extradata.map { ["config": $0] },
                                                    "cezium.apple",
                                                    workspaceToken: workspaceToken)
                        strongSelf.samples.append(samp)
                    }
                }
            }
        }
        if #available(iOS 9.0, macOS 10.11, tvOS 10.2, *) {
            VTCompressionSessionEncodeFrame(session,
                                            imageBuffer: image.pixelBuffer,
                                            presentationTimeStamp: CMTime(value: sample.pts().value,
                                                                          timescale: Int32(sample.pts().scale)),
                                            duration: CMTime.indefinite,
                                            frameProperties: nil,
                                            infoFlagsOut: nil,
                                            outputHandler: outputHandler)
        } else {
            throw AppleVideoEncoderError.invalidSystemVersion
        }
    }
    private var samples = [CodedMediaSample]()
    private let queue: DispatchQueue
    private let format: MediaFormat
    private var session: VTCompressionSession?
}

func pixelBufferOptions(_ frame: CGSize) -> CFDictionary {
    #if os(iOS)
    return [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int32(frame.width),
        kCVPixelBufferHeightKey as String: Int32(frame.height),
        kCVPixelBufferOpenGLESCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
    #else
    return [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int32(frame.width),
        kCVPixelBufferHeightKey as String: Int32(frame.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
    #endif
}

#endif
