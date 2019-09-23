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

import SwiftFFmpeg
import Foundation

public class FFmpegVideoEncoder : Tx<PictureSample, CodedMediaSample> {
    private let kTimebase: Int64 = 600600
    public init(_ format: MediaFormat, 
                crf: Int? = nil,
                bitrate: Int? = nil,
                keyframeInterval: TimePoint = TimePoint(600600*2,600600),
                frameDuration: TimePoint = TimePoint(1000, 60000),
                settings: EncoderSpecificSettings? = nil) {
        self.codecContext = nil
        self.format = format
        self.settings = settings
        self.crf = crf
        self.bitrate = bitrate
        self.frameDuration = frameDuration
        self.keyframeInterval = rescale(keyframeInterval, kTimebase)
        self.lastKeyframe = TimePoint(-keyframeInterval.value, kTimebase)
        self.frameNumber = 0
        self.timestamps = Array(repeating: TimePoint(0, kTimebase), count: Int(frameDuration.scale / frameDuration.value) * 10)

        print("keyframeinterval = \(keyframeInterval.toString())")
        super.init()
        super.set { [weak self] in
            guard let strongSelf = self else {
                return .gone
            }
            return strongSelf.handle($0)
        }
    }
    
    deinit {
        print("VideoEncoder deinit")
    }

    private func handle(_ sample: PictureSample) -> EventBox<CodedMediaSample> {
        if self.codecContext == nil {
            do {
                try setupContext(sample)
            } catch (let error) {
                print("setupContext error \(error)")
                return .error(EventError("enc.video.ffmpeg", -1, "Codec setup error \(error)", assetId: sample.assetId()))
            }
        }

        return encode(sample)
    }

    private func encode(_ sample: PictureSample) -> EventBox<CodedMediaSample> {
        guard let codecContext = self.codecContext else {
            return .nothing(sample.info())
        }
        do {
            //print("video in \(seconds(sample.pts()))")
            let frame = try makeAVFrame(sample)
            let packet = AVPacket()
            defer {
                packet.unref()
            }

            try codecContext.sendFrame(frame)
            try codecContext.receivePacket(packet)

            guard let data = packet.data else {
                return .nothing(sample.info())
            }
            let buffer = Data(bytes: data, count: packet.size)
            let extradata = codecContext.extradata <??> { bytes -> Data? in
                    let data = Data(bytes: bytes, count: codecContext.extradataSize)
                    return self.format == .avc ? avcDecoderConfigurationRecord(data) : data
            } <|> nil
            let dts = self.timestamps[Int(packet.dts) % self.timestamps.count]
            let pts = self.timestamps[Int(packet.pts) % self.timestamps.count]
            let sidedata: [String:Data]? = extradata <??> { ["config": $0] } <|> nil
            let outsample = CodedMediaSample(sample.assetId(), 
                                          sample.workspaceId(), 
                                          sample.time(),        // incorrect, needs to be matched with packet
                                          pts,
                                          dts,
                                          .video,
                                          self.format,
                                          buffer,
                                          sidedata,
                                          "enc.video.ffmpeg.\(format)",
                                          workspaceToken: sample.workspaceToken(),
                                          eventInfo: sample.info())
            outsample.info()?.addSample("enc.video.delay", sample.pts() - outsample.pts())
            //print("video out \(seconds(sample.pts()))")
            return .just(outsample)
        } catch let error as AVError where error == .tryAgain {
            return .nothing(sample.info())
        } catch let error {
            print("error \(error)")
            return .error(EventError("enc.video.ffmpeg", -2, "Encode error \(error)", assetId: sample.assetId()))
        }
    }

    private func makeAVFrame(_ sample: PictureSample) throws -> AVFrame {
        guard let imageBuffer = sample.imageBuffer() else {
            throw EncodeError.invalidImageBuffer
        }
        let frame = AVFrame()
        frame.pixelFormat = try getAVPixelFormat(sample.pixelFormat())
        frame.width = Int(sample.size().x)
        frame.height = Int(sample.size().y)

        let pts = rescale(sample.pts(), kTimebase)
        frame.pts = self.frameNumber
        self.frameNumber = self.frameNumber &+ 1
        self.timestamps[Int(self.frameNumber) % self.timestamps.count] = pts
        let nextKeyframe = (self.lastKeyframe + self.keyframeInterval) 
        if pts >= nextKeyframe {
            self.lastKeyframe = pts
            frame.pictureType = .I
            frame.isKeyFrame = true
        } else {
            frame.pictureType = .none
        }
        try frame.allocBuffer()
        sample.lock()
        defer {
            sample.unlock()
        }
        for i in 0..<imageBuffer.planes.count {
            try imageBuffer.withUnsafeMutableRawPointer(forPlane: i) { 
                guard let ptr = frame.data[i], let src = $0 else {
                    throw AVError.tryAgain
                }
                let dst = UnsafeMutableRawPointer(ptr)
                let srcStride = imageBuffer.planes[i].stride
                let dstStride = Int(frame.linesize[i])
                let srcHeight = Int(imageBuffer.planes[i].size.y)
                if srcStride == dstStride {
                    let bytes = srcHeight * srcStride
                    dst.copyMemory(from: src, byteCount: bytes)
                } else {
                    for j in 0..<srcHeight {
                        let toCopy = min(srcStride, dstStride)
                        (dst+(dstStride*j)).copyMemory(from: src+(srcStride*j), byteCount: toCopy)
                    }
                }
            }
        }
        return frame
    }
    private func setupContext(_ sample: PictureSample) throws {
        let name: String = try {
            switch format {
                case .avc: return "libx264" //return hwaccel ? "h264_nvenc" : "libx264"
                case .hevc: return "libx265" //return hwaccel ? "h265_nvenc" : "libx265"
                case .vp8: return "libvpx"
                case .vp9: return "libpvx-vp9"
                default: throw EncodeError.invalidMediaFormat
            }
        }()
        let pixelFormat = try getAVPixelFormat(sample.pixelFormat())
        guard let codec = AVCodec.findEncoderByName(name) else {
            throw EncodeError.encoderNotFound
        }
        let codecContext = AVCodecContext(codec: codec)
        codecContext.width = Int(sample.size().x)
        codecContext.height = Int(sample.size().y)
        codecContext.timebase = AVRational(num: 1, den: Int32(frameDuration.scale / frameDuration.value))
        codecContext.gopSize = -1
        codecContext.pixelFormat = pixelFormat
        codecContext.flags = [.globalHeader]
        if let bitrate = self.bitrate {
            codecContext.bitRate = Int64(bitrate)
            codecContext.bitRateTolerance = 0
        }
        try codecContext.openCodec(options: codecOptions(codecContext, 
                                                         format: format, 
                                                         settings: self.settings, 
                                                         bitrate: self.bitrate, 
                                                         crf: self.crf))
        self.codecContext = codecContext
    }

    
    let keyframeInterval: TimePoint
    let format: MediaFormat
    let settings: EncoderSpecificSettings?
    let crf: Int?
    let bitrate: Int?
    let frameDuration: TimePoint
    var frameNumber: Int64
    var lastKeyframe: TimePoint
    var timestamps: [TimePoint]
    var codecContext: AVCodecContext?
}

fileprivate func getAVPixelFormat(_ format : PixelFormat) throws -> AVPixelFormat {
    return try {
            switch format {
                case .y420p: return .YUV420P
                case .yuvs: return .YUYV422
                case .zvuy: return .UYVY422
                case .y422p: return .YUV422P
                case .y444p: return .YUV444P
                case .nv12: return .NV12
                case .nv21: return .NV21
                default: throw EncodeError.invalidPixelFormat
            }
        }()
}
fileprivate func codecOptions(_ context: AVCodecContext, 
        format: MediaFormat, 
        settings: EncoderSpecificSettings?,
        bitrate: Int?, 
        crf: Int?) -> [String: String] {
    switch format  {
        case .avc:
            return x264opts(context, settings: settings, bitrate, crf)
        case .vp8, .vp9:
            return ["slices": "4", "threads": "4"]
        default:
            return [:]
    }
}

fileprivate func x264opts(_ context: AVCodecContext, settings: EncoderSpecificSettings?, _ bitrate: Int?, _ crf: Int?) -> [String: String] {
    let avcSettings = settings <??> { if case .avc(let settings) = $0 { return settings }; return AVCSettings() } <|> AVCSettings()
    if avcSettings.useHWAccel {
        return [:]
    }
    var x264str = "annexb=0:aud=0:sync-lookahead=0:no-mbtree:sliced-threads" // mandatory, data is expected in AVC (ISO/IEC 14496-15) format.
    x264str += ":slices=4"
    if !avcSettings.useBFrames {
        x264str += ":bframes=0"
        context.maxBFrames = 0
    } else {
        context.maxBFrames = 3
    }
    if let bitrate = bitrate {
        x264str += ":bitrate=\(bitrate/1000):vbv-maxrate=\(bitrate/1000):vbv-bufsize=\(bitrate/1000)"
    }
    if let crf = crf {
        x264str += ":qpmax=\(crf)"
    }
    return ["x264opts": x264str, "profile": avcSettings.profile, "preset": avcSettings.preset]
}

fileprivate func avcDecoderConfigurationRecord(_ config: Data) -> Data? {
    guard config.count > 4 else {
        return nil
    }
    let spsSize = Int(config[0] << 24) | Int(config[1]) << 16 | Int(config[2]) << 8 | Int(config[3])
    guard spsSize+4+4 < config.count else {
        return nil
    }
    let ppsSize = Int(config[spsSize+4] << 24) | Int(config[spsSize+5] << 16)  |  Int(config[spsSize+6] << 8) | Int(config[spsSize+7])
    guard spsSize+ppsSize+8 <= config.count else {
        return nil
    }
    let be16 = { (num: Int16) -> [UInt8] in
        [UInt8((num >> 8) & 0xff), UInt8(num & 0xff)]
    }
    let spsRead = buffer.readBytes(buffer.fromData(config[4..<(4+spsSize)]), length: spsSize)
    let ppsRead = buffer.readBytes(buffer.fromData(config[(4+spsSize+4)..<(4+spsSize+ppsSize+4)]), length: ppsSize)
    guard let spsBytes = spsRead.1, let ppsBytes = ppsRead.1 else {
        return nil
    }
    let ppsSizeBytes: [UInt8] = be16(Int16(ppsSize))
    let spsSizeBytes: [UInt8]  = be16(Int16(spsSize))
    let headerBytes: [UInt8] = [0x1, config[5], config[6], config[7], 0xFF, 0xE1]
    let one: [UInt8] = [0x1]
    let bytes: [UInt8] = headerBytes + spsSizeBytes + spsBytes + one + ppsSizeBytes + ppsBytes
    
    return Data(bytes)
}