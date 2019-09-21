import Foundation

public func audioStats() -> Tx<AudioSample, AudioSample> {
    return Tx { sample in
        let channels = sample.numberChannels()
        if let info = sample.info() {
            var peak: Array<Float> = Array(repeating: 0, count: channels)
            var rms: Array<Float> = Array(repeating: 0, count: channels)
            switch sample.format() {
            case .s16i, .s16p:
                var accum: Array<Int> = Array(repeating: 0, count: channels) 
                var i16peak: Array<Int> = Array(repeating: 0, count: channels)
                iterate(sample, as: Int16.self) { (channel, sample) in 
                    let a = abs(Int(sample))
                    if a > i16peak[channel] {
                        i16peak[channel] = a
                    }
                    let sq = Int(sample)*Int(sample)
                    accum[channel] += sq
                }
                for i in 0..<channels {
                    peak[i] = Float(i16peak[i]) / Float(32768)
                    rms[i] = sqrt(Float(accum[i])/Float(sample.numberSamples()))/Float(32768)
                }
            case .f32i, .f32p:
                iterate(sample, as: Float.self) { (channel, sample) in 
                    let a = abs(sample)
                    if a > peak[channel] {
                        peak[channel] = a
                    }
                    let sq = sample*sample
                    rms[channel] += sq
                }
                for i in 0..<channels {
                    rms[i] = sqrt(rms[i]/Float(sample.numberSamples()))
                }
            default:
                ()
            }
            for i in 0..<channels {
                info.addSample("audio.peak.\(i)", Double(peak[i]))
                info.addSample("audio.rms.\(i)", Double(rms[i]))
            }
        }
        return .just(sample)
    }
}


// Channel Index, Sample Data Type,
fileprivate func iterate<T>(_ sample: AudioSample, as: T.Type, fn: (Int, T) -> ()){
    let planar = isPlanar(sample.format())
    let samples = sample.numberSamples()
    let channels = sample.numberChannels()
    let sampleBytes = bytesPerSample(sample.format(), channels)
    let bufferBytes = sampleBytes * samples
    sample.data().enumerated().forEach { (idx, buffer) in
        let count = min(buffer.count, bufferBytes) / MemoryLayout<T>.size
        guard count > 0 else {
            return
        }
        buffer.withUnsafeBytes { ptr in 
            let bound = ptr.bindMemory(to: T.self)
            for i in 0..<count {
                let channel = planar ? idx : i % channels
                fn(channel, bound[i])
            }
        }
    }
}