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

#if !EXCLUDE_FFMPEG

import SwiftFFmpeg
import Foundation
import VectorMath

private let kTimebase: Int64 = 600600

public class FFmpegVideoDecoder: Tx<CodedMediaSample, PictureSample> {
    public override init() {
        self.codec = nil
        self.codecContext = nil
        self.extradata = nil
        super.init()
        super.set { [weak self] in
            guard let strongSelf = self else {
                return .gone
            }
            return strongSelf.handle($0)
        }
    }
    deinit {
        if extradata != nil {
            AVIO.freep(extradata)
        }
        print("VideoDecoder deinit")
    }
    private func handle(_ sample: CodedMediaSample) -> EventBox<PictureSample> {
        guard sample.mediaType() == .video else {
            return .error(EventError("dec.video.ffmpeg",
                            -1, "Only video samples are supported", assetId: sample.assetId()))
        }
        if self.codecContext == nil {
            do {
                try setupContext(sample)
            } catch let err {
                print("Context setup error \(err)")
                return .error(EventError("dec.video.ffmpeg",
                                -2, "Error creating codec context \(err)", assetId: sample.assetId()))
            }
        }
        do {
            return try decode(sample)
        } catch let error {
            print("decode error \(error)")
            return .error(EventError("dec.video.ffmpeg",
                            -3, "Error decoding bitstream \(error)", assetId: sample.assetId()))
        }
    }

    private func decode(_ sample: CodedMediaSample) throws -> EventBox<PictureSample> {
        guard let codecCtx = self.codecContext else {
            return .error(EventError("dec.video.ffmpeg", -4, "No codec context", assetId: sample.assetId()))
        }

        guard sample.data().count > 0 else {
            return .nothing(sample.info())
        }

        let pts = rescale(sample.pts(), kTimebase)
        let dts = rescale(sample.dts(), kTimebase)
        let packet = AVPacket()
        let size = sample.data().count
        var data = sample.data()

        try packet.makeWritable()

        data.withUnsafeMutableBytes {
            guard let buffer = packet.buffer,
                  let baseAddress = $0.baseAddress else {
                return
            }
            buffer.realloc(size: size)
            memcpy(buffer.data, baseAddress, size)
        }
        packet.data = packet.buffer?.data
        packet.size = size
        packet.pts = pts.value
        packet.dts = dts.value

        if packet.size > 0 {
            try codecCtx.sendPacket(packet)
            do {
                let frame = AVFrame()
                try codecCtx.receiveFrame(frame)
                return makePictureSample(frame, sample: sample)
            } catch let error as AVError where error == .tryAgain {
                return .nothing(sample.info())
            }
        }
        return .nothing(sample.info())
    }

    private func setupContext(_ sample: CodedMediaSample) throws {
        self.codec = {
                switch sample.mediaFormat() {
                case .avc: return AVCodec.findDecoderById(.H264)
                case .hevc: return AVCodec.findDecoderById(.HEVC)
                case .vp8: return AVCodec.findDecoderById(.VP8)
                case .vp9: return AVCodec.findDecoderById(.VP9)
                case .png: return AVCodec.findDecoderById(.PNG)
                case .apng: return AVCodec.findDecoderById(.APNG)
                default: return nil
                } }()
        if let codec = self.codec {
            let ctx = AVCodecContext(codec: codec)
            self.codecContext = ctx
        }
        if let context = self.codecContext {
            if let sideData = sample.sideData()["config"],
               let mem =  AVIO.malloc(size: sideData.count + AVConstant.inputBufferPaddingSize) {
                    let memBuf = UnsafeMutableRawBufferPointer(start: mem,
                                        count: sideData.count + AVConstant.inputBufferPaddingSize)
                    _ = memBuf.baseAddress.map {
                        sideData.copyBytes(to: $0.assumingMemoryBound(to: UInt8.self), count: sideData.count)
                        context.extradata = $0.assumingMemoryBound(to: UInt8.self)
                        context.extradataSize = sideData.count
                    }
            }
            try context.openCodec()
        }
    }

    var codec: AVCodec?
    var codecContext: AVCodecContext?
    var extradata: UnsafeMutableRawPointer?
}

private func frameData(_ frame: AVFrame) -> [Data] {
    (0..<3).compactMap { idx -> Data? in
        guard let data = frame.data[idx], frame.linesize[idx] > 0 else {
            return nil
        }
        if idx == 0 {
            return Data(bytesNoCopy: data,
                count: Int(frame.linesize[idx]) * Int(frame.height),
                deallocator: .custom({ _, _ in
                    frame.unref()
                }))
        } else {
            let height = frame.pixelFormat == .YUV420P ? frame.height / 2 : frame.height
            return Data(bytesNoCopy: data, count: Int(frame.linesize[idx]) * Int(height), deallocator: .none)
        }
    }
}

private func planeSize(_ frame: AVFrame, _ idx: Int, _ pixelFormat: PixelFormat) -> Vector2 {
    switch pixelFormat {
    case .y420p, .nv12, .nv21:
        return idx == 0 ? Vector2(Float(frame.width),
                            Float(frame.height)) : Vector2(Float(frame.width/2), Float(frame.height/2))
    case .yuvs, .zvuy, .y444p, .BGRA, .RGBA:
        return Vector2(Float(frame.width), Float(frame.height))
    case .y422p:
        return idx == 0 ? Vector2(Float(frame.width),
                            Float(frame.height)) : Vector2(Float(frame.width/2), Float(frame.height))
    default: return Vector2(0, 0)
    }
}

private func framePlanes(_ frame: AVFrame, pixelFormat: PixelFormat) -> [Plane] {
    (0..<3).compactMap { idx -> Plane? in
        guard frame.linesize[idx] > 0 else {
            return nil
        }
        let size = planeSize(frame, idx, pixelFormat)
        let components: [Component] = componentsForPlane(pixelFormat, idx)
        return Plane(size: size, stride: Int(frame.linesize[idx]), bitDepth: 8, components: components)
    }
}

private func makePictureSample(_ frame: AVFrame, sample: CodedMediaSample) -> EventBox<PictureSample> {
    let pixelFormat = fromFfPixelFormat(frame)
    let data = frameData(frame)
    let planes = framePlanes(frame, pixelFormat: pixelFormat)
    do {
        let image = try ImageBuffer(pixelFormat: pixelFormat,
                            bufferType: .cpu,
                            size: Vector2(Float(frame.width), Float(frame.height)),
                            buffers: data,
                            planes: planes)
        let pts = TimePoint(frame.pts, kTimebase)
        return .just(PictureSample(image,
                             assetId: sample.assetId(),
                             workspaceId: sample.workspaceId(),
                             workspaceToken: sample.workspaceToken(),
                             time: sample.time(),
                             pts: pts))
    } catch let error {
        print("caught error \(error)")
        return .error(EventError("dec.video.ffmpeg",
                        -5, "Error creating image \(error)", assetId: sample.assetId()))
    }
}

private func fromFfPixelFormat(_ frame: AVFrame) -> PixelFormat {
    [.YUV420P: .y420p,
     .YUYV422: .yuvs,
     .UYVY422: .zvuy,
     .YUV422P: .y422p,
     .YUV444P: .y444p,
     .NV12: .nv12,
     .NV21: .nv21,
     .BGRA: .BGRA,
     .RGBA: .RGBA][frame.pixelFormat] ?? .invalid
}

#endif // !EXCLUDE_FFMPEG