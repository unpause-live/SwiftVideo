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

#if USE_FFMPEG

import SwiftFFmpeg
import Foundation

public class AudioSampleRateConversion: Tx<AudioSample, AudioSample> {
    public init(_ outFrequency: Int, _ outChannelCount: Int, _ outAudioFormat: AudioFormat) {
        self.swrCtx = nil
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            if outFrequency == sample.sampleRate() &&
                outChannelCount == sample.numberChannels() &&
                outAudioFormat == sample.format() {
                return .just(sample)
            }
            if strongSelf.swrCtx == nil {
                strongSelf.pts = rescale(sample.pts(), Int64(outFrequency))
                strongSelf.makeContext(sample,
                                       frequency: outFrequency,
                                       channelCount: outChannelCount,
                                       format: outAudioFormat)
            }
            return strongSelf.resample(sample,
                                       frequency: outFrequency,
                                       outChannelCount: outChannelCount,
                                       format: outAudioFormat)
        }
    }

    private func resample(_ sample: AudioSample,
                          frequency: Int,
                          outChannelCount: Int,
                          format: AudioFormat) -> EventBox<AudioSample> {
        guard let swrCtx = self.swrCtx, let pts = self.pts else {
            return .nothing(sample.info())
        }

        let srcSampleRate = Int64(sample.sampleRate())
        let dstSampleRate = Int64(frequency)
        let srcSamples = AVSamples(channelCount: sample.numberChannels(),
                                   sampleCount: sample.numberSamples(),
                                   sampleFormat: avSampleFormat(sample.format()))
        let srcSampleCount = Int64(swrCtx.getDelay(srcSampleRate) + sample.numberSamples())
        let dstMaxSampleCount = Int(AVMath.rescale(Int64(sample.numberSamples()), dstSampleRate, srcSampleRate, .up))
        let dstSampleCount = Int(AVMath.rescale(srcSampleCount, dstSampleRate, srcSampleRate, .up))
        let dstSamples: AVSamples = {
            if dstSampleCount <= dstMaxSampleCount {
                return AVSamples(channelCount: outChannelCount,
                          sampleCount: dstMaxSampleCount,
                          sampleFormat: avSampleFormat(format),
                          align: 0)
            } else {
                return  AVSamples(channelCount: outChannelCount,
                          sampleCount: dstSampleCount,
                          sampleFormat: avSampleFormat(format),
                          align: 1)
            }
        }()

        sample.data().enumerated().forEach { (idx, buffer) in
            let bufferSize = min(buffer.count, srcSamples.size)
            buffer.withUnsafeBytes {
                guard let data = srcSamples.data[idx], let baseAddress = $0.baseAddress else {
                    return
                }
                memcpy(data, baseAddress, bufferSize)
            }
        }
        do {
            let count = try srcSamples.reformat(using: swrCtx, to: dstSamples)
            guard count > 0 else {
                return .nothing(sample.info())
            }
            let (size, _) = try AVSamples.getBufferSize(channelCount: outChannelCount,
                                                        sampleCount: count,
                                                        sampleFormat: avSampleFormat(format),
                                                        align: 1)
            let bufferCount = numberOfBuffers(format, outChannelCount)
            let buffers = ((0..<bufferCount) as CountableRange).compactMap { (idx) -> Data? in
                guard let data = dstSamples.data[idx] else {
                    return nil
                }
                return Data(bytes: data, count: size)
            }
            self.pts = pts + TimePoint(Int64(count), Int64(frequency))
            let outSample = AudioSample(sample,
                                        bufferType: .cpu,
                                        buffers: buffers,
                                        frequency: frequency,
                                        channels: outChannelCount,
                                        format: format,
                                        sampleCount: count,
                                        pts: pts)
            return .just(outSample)
        } catch let error {
            print("SRC error \(error) \(sample.format()) \(sample.numberChannels()) \(sample.numberSamples())")
            return .error(EventError("src.audio.ffmpeg", -1, "conversion error \(error)",
                sample.time(),
                assetId: sample.assetId()))
        }
    }

    private func makeContext(_ sample: AudioSample, frequency: Int, channelCount: Int, format: AudioFormat) {
        // source
        // TODO: Support surround sound for > 2 channels
        let srcChannelLayout = sample.numberChannels() == 2 ? AVChannelLayout.CHL_STEREO : AVChannelLayout.CHL_MONO
        let srcSampleRate = sample.sampleRate()
        let srcSampleFmt = avSampleFormat(sample.format())

        // destination
        let dstChannelLayout = channelCount > 1 ? AVChannelLayout.CHL_STEREO : AVChannelLayout.CHL_MONO
        let dstSampleRate = Int64(frequency)
        let dstSampleFmt = avSampleFormat(format)

        do {
            let ctx = SwrContext()
            try ctx.set(srcChannelLayout.rawValue, forKey: "in_channel_layout")
            try ctx.set(srcSampleRate, forKey: "in_sample_rate")
            try ctx.set(srcSampleFmt, forKey: "in_sample_fmt")
            try ctx.set(dstChannelLayout.rawValue, forKey: "out_channel_layout")
            try ctx.set(dstSampleRate, forKey: "out_sample_rate")
            try ctx.set(dstSampleFmt, forKey: "out_sample_fmt")
            try ctx.set("soxr", forKey: "resampler")
            try ctx.set(24, forKey: "precision") // Set to 28 for higher bit-depths than 16-bit
            try ctx.set(1.0, forKey: "rematrix_maxval")
            try ctx.set("triangular", forKey: "dither_method")

            try ctx.initialize()
            self.swrCtx = ctx
        } catch let error {
            print("SwrContext error \(error)")
        }
    }
    private var swrCtx: SwrContext?
    private var pts: TimePoint?
}

private func avSampleFormat(_ fmt: AudioFormat) -> AVSampleFormat {
    switch fmt {
    case .s16i:
        return .s16
    case .s16p:
        return .s16p
    case .f32p:
        return .fltp
    case .f32i:
        return .flt
    case .f64p:
        return .dblp
    case .f64i:
        return .dbl
    default:
        return .s16
    }
}

#endif // USE_FFMPEG
