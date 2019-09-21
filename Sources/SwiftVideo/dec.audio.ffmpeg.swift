import SwiftFFmpeg
import Foundation
import VectorMath

public class FFmpegAudioDecoder : Tx<CodedMediaSample, AudioSample> {
    private let kTimebase : Int64 = 96000
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
        print("AudioDecoder deinit")
    }
    private func handle(_ sample: CodedMediaSample) -> EventBox<AudioSample> {
        guard sample.mediaType() == .audio else {
            return .error(EventError("dec.sound.ffmpeg", -1, "Only audio samples are supported", assetId: sample.assetId()))
        }
        if self.codecContext == nil {
            do {
                try setupContext(sample)
            } catch (let err) {
                return .error(EventError("dec.sound.ffmpeg", -2, "Error creating codec context \(err)", assetId: sample.assetId()))
            }
        }
        do {
            return try decode(sample)
        } catch(let error) {
            print("decode error \(error)")
            return .error(EventError("dec.sound.ffmpeg", -3, "Error decoding bitstream \(error)", assetId: sample.assetId()))    
        }
    }

    private func decode(_ sample: CodedMediaSample) throws -> EventBox<AudioSample> {
        guard let codecCtx = self.codecContext else {
            return .error(EventError("dec.sound.ffmpeg", -4, "No codec context", assetId: sample.assetId()))
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
            buffer.realloc(size:size)
            memcpy(buffer.data, baseAddress, size)
        }
        packet.data = packet.buffer?.data
        packet.size = size
        packet.pts = pts.value
        packet.dts = dts.value
        
        if(packet.size > 0) {
            try codecCtx.sendPacket(packet)
            do {
                let frame = AVFrame()
                try codecCtx.receiveFrame(frame)
                
                let channelCt = codecCtx.channelCount
                let sampleCt = frame.sampleCount
                let sampleRate = codecCtx.sampleRate
                let (format, bytesPerSample) = { () -> (AudioFormat, Int) in
                    switch(frame.sampleFormat) {
                        case .s16:
                            return (.s16i, codecCtx.sampleFormat.bytesPerSample * channelCt)
                        case .s16p:
                            return (.s16p, codecCtx.sampleFormat.bytesPerSample)
                        case .flt:
                            return (.f32i, codecCtx.sampleFormat.bytesPerSample * channelCt)
                        case .fltp:
                            return (.f32p, codecCtx.sampleFormat.bytesPerSample)
                        case .dbl:
                            return (.f64i, codecCtx.sampleFormat.bytesPerSample * channelCt)
                        case .dblp:
                            return (.f64p, codecCtx.sampleFormat.bytesPerSample)
                        default: 
                            return (.invalid, 0)
                    }
                }()
                let data = (0..<channelCt).compactMap { idx -> Data? in
                    guard let data = frame.data[idx], bytesPerSample > 0 else {
                        return nil
                    }
                    if idx == 0 {
                        return Data(bytesNoCopy: data, count: bytesPerSample * sampleCt, deallocator: .custom({ _, _ in
                                frame.unref()
                            }))
                    } else {
                        return Data(bytesNoCopy: data, count: bytesPerSample * sampleCt, deallocator: .none)
                    }
                }
                let pts = self.pts ?? rescale(TimePoint(frame.pts,kTimebase), Int64(sampleRate))
                let dur = TimePoint(Int64(sampleCt), Int64(sampleRate))
                self.pts = pts + dur
                let sample = AudioSample(data, 
                                         frequency: sampleRate,
                                         channels: channelCt,
                                         format: format,
                                         sampleCount: sampleCt,
                                         time: sample.time(),
                                         pts: pts,
                                         assetId: sample.assetId(),
                                         workspaceId: sample.workspaceId(),
                                         workspaceToken: sample.workspaceToken())
                return .just(sample)
            } catch let error as AVError where error == .tryAgain {
                return .nothing(sample.info())
            }
        }
        return .nothing(sample.info())
    }

    private func setupContext(_ sample: CodedMediaSample) throws {
        self.codec = {
                switch sample.mediaFormat() {
                    case .aac: return AVCodec.findDecoderByName("libfdk_aac")
                    case .opus: return AVCodec.findDecoderByName("libopus")
                    default: return nil
                } }()
        if let codec = self.codec {
            let ctx = AVCodecContext(codec: codec)
            self.codecContext = ctx
        } else {
            print("No codec!")
        }
        if let context = self.codecContext {
            if let sideData = sample.sideData()["config"],
               let mem =  AVIO.malloc(size: sideData.count + AVConstant.inputBufferPaddingSize) {
                    let memBuf = UnsafeMutableRawBufferPointer(start: mem, count: sideData.count + AVConstant.inputBufferPaddingSize)
                    _ = memBuf.baseAddress.map {
                        sideData.copyBytes(to: $0.assumingMemoryBound(to: UInt8.self), count: sideData.count)
                        context.extradata = $0.assumingMemoryBound(to: UInt8.self)
                        context.extradataSize = sideData.count
                    }
            }
            try context.openCodec()
        }
    }
    var pts: TimePoint?
    var codec: AVCodec?
    var codecContext: AVCodecContext?
    var extradata: UnsafeMutableRawPointer?
}
