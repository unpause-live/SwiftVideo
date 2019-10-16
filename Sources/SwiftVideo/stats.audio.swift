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

import Foundation

public func audioStats() -> Tx<AudioSample, AudioSample> {
    return Tx { sample in
        let channels = sample.numberChannels()
        if let info = sample.info() {
            var peak: [Float] = Array(repeating: 0, count: channels)
            var rms: [Float] = Array(repeating: 0, count: channels)
            switch sample.format() {
            case .s16i, .s16p:
                var accum: [Int] = Array(repeating: 0, count: channels)
                var i16peak: [Int] = Array(repeating: 0, count: channels)
                iterate(sample, as: Int16.self) { (channel, sample) in
                    let val = abs(Int(sample))
                    if val > i16peak[channel] {
                        i16peak[channel] = val
                    }
                    let sqr = Int(sample)*Int(sample)
                    accum[channel] += sqr
                }
                for idx in 0..<channels {
                    peak[idx] = Float(i16peak[idx]) / Float(32768)
                    rms[idx] = sqrt(Float(accum[idx])/Float(sample.numberSamples()))/Float(32768)
                }
            case .f32i, .f32p:
                iterate(sample, as: Float.self) { (channel, sample) in
                    let val = abs(sample)
                    if val > peak[channel] {
                        peak[channel] = val
                    }
                    let sqr = sample*sample
                    rms[channel] += sqr
                }
                for idx in 0..<channels {
                    rms[idx] = sqrt(rms[idx]/Float(sample.numberSamples()))
                }
            default:
                ()
            }
            for idx in 0..<channels {
                info.addSample("audio.peak.\(idx)", Double(peak[idx]))
                info.addSample("audio.rms.\(idx)", Double(rms[idx]))
            }
        }
        return .just(sample)
    }
}

// Channel Index, Sample Data Type,
// swiftlint:disable:next identifier_name
private func iterate<T>(_ sample: AudioSample, as: T.Type, fn: (Int, T) -> Void) {
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
            for elem in 0..<count {
                let channel = planar ? idx : elem % channels
                fn(channel, bound[elem])
            }
        }
    }
}
