import SwiftFFmpeg
import Foundation

public class FFmpegAudioEncoder : Tx<AudioSample, [CodedMediaSample]> {
    private let kTimebase: Int64 = 96000
    public init(_ format: MediaFormat, 
                bitrate: Int) {
        self.codecContext = nil
        self.format = format
        self.bitrate = bitrate
        self.frameNumber = 0
        self.accumulators = [Data]()
        self.pts = nil
        super.init()
        super.set { [weak self] in
            guard let strongSelf = self else {
                return .gone
            }
            return strongSelf.handle($0)
        }
    }

    deinit {
        print("AudioEncoder deinit")
    }

    private func handle(_ sample: AudioSample) -> EventBox<[CodedMediaSample]> {
        if self.codecContext == nil {
            do {
                try setupContext(sample)
            } catch (let error) {
                print("setupContext error \(error)")
                return .error(EventError("enc.audio.ffmpeg", -1, "Codec setup error \(error)", assetId: sample.assetId()))
            }
        }
        //if self.pts == nil {
        //    self.pts = sample.pts()
        //}
        return encode(sample)
    }

    private func encode(_ sample: AudioSample) -> EventBox<[CodedMediaSample]> {
        guard let codecContext = self.codecContext else {
            return .nothing(sample.info())
        }
        var samples = [CodedMediaSample]()
        do {
            //print("audio in \(seconds(sample.pts()))")
            var frames = try makeAVFrame(sample)
            
            while frames.count > 0 {
                do {
                    try codecContext.sendFrame(frames[0])
                    _ = frames.removeFirst()
                } catch let error as AVError where error == .tryAgain {}

                do {
                    repeat {
                        let packet = AVPacket()
                        defer {
                            packet.unref()
                        }
                        try codecContext.receivePacket(packet)

                        guard let data = packet.data, packet.size > 0 else {
                            throw AVError.tryAgain
                        }
                        let frameDuration =  TimePoint(Int64(codecContext.frameSize), Int64(codecContext.sampleRate))
                        let pts = self.pts ?? rescale(sample.pts(), Int64(codecContext.sampleRate))
                        self.frameNumber = self.frameNumber &+ 1
                        let buffer = Data(bytes: data, count: packet.size)
                        let extradata = codecContext.extradata.map { Data(bytes: $0, count: codecContext.extradataSize) }
                        let dts = pts
                        self.pts = pts + frameDuration
                        let sidedata: [String:Data]? = extradata.map { ["config": $0] }
                        let sample = CodedMediaSample(sample.assetId(), 
                                                      sample.workspaceId(), 
                                                      sample.time(),        // incorrect, needs to be matched with packet
                                                      pts,
                                                      dts,
                                                      .audio,
                                                      self.format,
                                                      buffer,
                                                      sidedata,
                                                      "enc.audio.ffmpeg.\(format)",
                                                      workspaceToken: sample.workspaceToken(),
                                                      eventInfo: sample.info())
                        //print("audio out \(seconds(sample.pts()))")
                        samples.append(sample)
                    } while true
                } catch let error as AVError where error == .tryAgain {}
            } 
            return .just(samples)
        } catch let error {
            print("error enc.audio.ffmpeg \(error)")
            return .error(EventError("enc.audio.ffmpeg", -2, "Encode error \(error)", assetId: sample.assetId()))
        }
    }

    private func makeAVFrame(_ sample: AudioSample) throws -> [AVFrame] {
        guard let codecCtx = self.codecContext else {
            throw EncodeError.invalidContext
        }
        var frames = [AVFrame]()
        sample.data().enumerated().forEach { (offset, buffer) in
            if self.accumulators.count == offset {
                self.accumulators.append(Data(capacity: buffer.count * 2))
            }
            self.accumulators[offset].append(buffer)
        }
        do {
            repeat {
                let frame = AVFrame()
                frame.sampleCount = codecCtx.frameSize
                frame.sampleFormat = codecCtx.sampleFormat
                frame.channelLayout = codecCtx.channelLayout
                
                try frame.allocBuffer()
                let isPlanar = sample.format() == .s16p || sample.format() == .f32p
                try (0..<self.accumulators.count).forEach { offset in
                    guard let ptr = frame.data[offset] else {
                        throw AVError.tryAgain
                    }
                    let requiredBytes = codecCtx.frameSize * codecCtx.sampleFormat.bytesPerSample * (isPlanar ? 1 : codecCtx.channelCount)
                    if self.accumulators[offset].count >= requiredBytes {
                        self.accumulators[offset].copyBytes(to: ptr, count: requiredBytes)
                        if self.accumulators[offset].count > requiredBytes {
                            self.accumulators[offset] = self.accumulators[offset].advanced(by: requiredBytes)
                        } else {
                            self.accumulators[offset].removeAll(keepingCapacity: true)
                        }
                    } else {
                        throw AVError.tryAgain
                    }
                }
                frames.append(frame)
            } while true
        } catch let error as AVError where error == .tryAgain {}
        return frames
    }
    private func setupContext(_ sample: AudioSample) throws {
        let name: String = try {
            switch format {
                case .aac: return "libfdk_aac"
                case .opus: return "libopus"
                default: throw EncodeError.invalidMediaFormat
            }
        }()
        guard let codec = AVCodec.findEncoderByName(name) else {
            throw EncodeError.encoderNotFound
        }
        let codecContext = AVCodecContext(codec: codec)
        codecContext.flags = [.globalHeader]
        codecContext.bitRate = Int64(bitrate)
        codecContext.sampleRate = sample.sampleRate()
        codecContext.sampleFormat = {
                switch sample.format() {
                    case .s16i:
                        return .s16
                    case .s16p:
                        return .s16p
                    case .f32p:
                        return .fltp
                    default:
                        return .s16
                }
            }()
        codecContext.channelLayout = .CHL_STEREO
        codecContext.channelCount = sample.numberChannels()
        codecContext.frameSize = sample.numberSamples()
        try codecContext.openCodec()
        self.codecContext = codecContext
    }

    let format: MediaFormat
    let bitrate: Int
    var accumulators: [Data]
    var frameNumber: Int64
    var pts: TimePoint?
    var codecContext: AVCodecContext?

}
