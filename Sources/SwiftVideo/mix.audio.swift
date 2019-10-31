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

import Dispatch
import Foundation
import VectorMath

public class AudioMixer: Source<AudioSample> {
    public init(_ clock: Clock,
                workspaceId: String,
                frameDuration: TimePoint,
                sampleRate: Int,
                channelCount: Int,
                delay: TimePoint? = nil,
                outputFormat: AudioFormat = .s16i,
                assetId: String? = nil,
                statsReport: StatsReport? = nil,
                epoch: Int64? = nil) {
        self.samples = [String: [AudioSample]]()
        self.frameDuration = frameDuration
        self.delay = delay ?? TimePoint(0, frameDuration.scale)
        self.clock = clock
        let now = clock.current()
        let epoch = rescale(epoch.map { clock.fromUnixTime($0) } ?? now, Int64(sampleRate))
        self.epoch = epoch
        self.pts = now - epoch
        self.idWorkspace = workspaceId
        let idAsset = assetId ?? UUID().uuidString
        self.idAsset = idAsset
        self.statsReport = statsReport ?? StatsReport(assetId: idAsset, clock: clock)
        self.queue = DispatchQueue(label: "mix.audio.\(idAsset)")
        self.sampleRate = sampleRate
        self.outputFormat = outputFormat
        self.channelCount = channelCount
        self.sourceOffset = [String: TimePoint]()
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            if sample.assetId() != strongSelf.assetId() {
                strongSelf.queue.async { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.samples = strongSelf.samples.merging([sample.assetId(): [sample]]) { $0 + $1 }
                    if strongSelf.sourceOffset[sample.assetId()] == nil {

                        let ptsOffset = strongSelf.pts + (frameDuration*2) - sample.pts()
                        strongSelf.sourceOffset[sample.assetId()] = ptsOffset
                    }
                }
                return .nothing(sample.info())
            } else {
                return .just(sample)
            }
        }
        clock.schedule(now + frameDuration) { [weak self] event in
            self?.queue.async { [weak self] in
                self?.mix(at: event)
            }
        }
    }
    deinit {
        print("exiting audio mixer")
    }
    public func assetId() -> String {
        return idAsset
    }

    public func workspaceId() -> String {
        return idWorkspace
    }

    public func getSampleRate() -> Int {
        return sampleRate
    }

    public func getChannels() -> Int {
        return channelCount
    }

    public func getAudioFormat() -> AudioFormat {
        return outputFormat
    }

    public func removeAsset(_ assetId: String) {
        queue.sync {
            self.samples.removeValue(forKey: assetId)
            self.sourceOffset.removeValue(forKey: assetId)
        }
    }

    public func discontinuity(_ assetId: String) {
        //print("discontinuity")
        self.sourceOffset.removeValue(forKey: assetId)
    }

    private func mix(at: ClockTickEvent) {
        let next = at.time() + frameDuration
        let mixTimestamp = at.time() - epoch
        self.pts = mixTimestamp
        clock.schedule(next) { [weak self] event in
            self?.queue.async { [weak self] in
                self?.mix(at: event)
            }
        }
        self.statsReport.endTimer("mix.audio.delta")
        self.statsReport.startTimer("mix.audio.delta")
        self.statsReport.startTimer("mix.audio.mix")

        let mixEndTimestamp = mixTimestamp + self.frameDuration
        let numBuffers = numberOfBuffers(self.outputFormat, self.channelCount)

        var buffers = ((0..<numBuffers) as CountableRange).map { _ -> Data in
                let numberSamples = Int(rescale(self.frameDuration, Int64(self.sampleRate)).value)
                let bufferSize = numberSamples * bytesPerSample(self.outputFormat, self.channelCount)
                return Data(count: bufferSize)
            }
        var constituents = [MediaConstituent]()
        let samples = self.samples.filter { $0.1.count > 0 }
        let result = samples.reduce([String: [AudioSample]]()) { (acc, curr) in
            let (assetId, queuedSamples) = curr
            guard let offset = self.sourceOffset[assetId], queuedSamples.count > 0 else {
                return acc
            }
            // Iterate through the queued samples for this asset, mixing each sample the appropriate time point
            // and filtering samples that occurred in the past
            var covered = (mixTimestamp + self.frameDuration, mixTimestamp)
            let unusedSamples = queuedSamples.filter { work in
                let workDuration = rescale(TimePoint(Int64(work.numberSamples()),
                                                     Int64(work.sampleRate())),
                                           work.pts().scale)
                // Normalize the sample PTS to match the mixer's time frame, plus some delay.
                let normalizedPts = work.pts() + offset + self.delay
                let normalizedEndTs = normalizedPts + rescale(workDuration, normalizedPts.scale)
                // If the normalied end timestamp is greater than the start of the current window period,
                // and the normalized start timestamp is less than the end of the window period
                // then this sample should be mixed.
                if normalizedEndTs >= mixTimestamp && normalizedPts < mixEndTimestamp {
                    let gains = self.channelGains(self.samplePosition(work))
                    let ptsDelta = normalizedPts - mixTimestamp
                    let offsetSamples = rescale(ptsDelta, Int64(self.sampleRate)).value
                    let inputOffsetSamples =
                        Int(ptsDelta.value < 0 ? TimePoint(abs(ptsDelta.value), Int64(work.sampleRate())).value : 0) *
                                                        bytesPerSample(work.format(), work.numberChannels())
                    let offset = max(Int(offsetSamples) * bytesPerSample(self.outputFormat, self.channelCount), 0)
                    //print("backing start offset=\(offset) input offset=\(inputOffsetSamples)")
                    // Mix each channel in the current work sample
                    work.data().enumerated().forEach { (idx, data) in
                        // TODO: Check format type to pick the correct function
                        guard idx < buffers.count else {
                            return
                        }
                        _ = self.applyMixS16(data,
                                gain: gains,
                                backing: &buffers[idx],
                                backingStartOffset: offset,
                                inputStartOffset: inputOffsetSamples)
                    }
                    covered = (clamp(normalizedPts,
                                     mixTimestamp,
                                     covered.0),
                               clamp(covered.1,
                                     normalizedEndTs,
                                     mixEndTimestamp))
                    return true
                    // Else, if the normalized end timestamp is greater than the start of this window period,
                    // keep the sample for later processing.
                } else if normalizedEndTs > mixTimestamp {
                    return true
                }
                // The sample is from the past and should be discarded.
                return false
            }
            if covered.1 > covered.0 {
                // we used some of this asset
                let duration = covered.1 - covered.0
                let pts = covered.0 - offset - self.delay
                let constituent = MediaConstituent.with {
                    $0.pts = pts
                    $0.idAsset = assetId
                    $0.duration = duration
                    $0.normalizedPts = covered.0
                }
                constituents.append(constituent)
            }
            if ((covered.0 > covered.1) ||
                (covered.1 != mixEndTimestamp)) &&
                unusedSamples.count != queuedSamples.count {
                let underrunDuration = max(TimePoint(0, 1000), covered.0 - mixTimestamp) +
                                       max(TimePoint(0, 1000), mixEndTimestamp - covered.1)
                self.statsReport.addSample("mix.audio.underrun", underrunDuration)
                self.discontinuity(assetId)
            }
            return acc.merging([assetId: unusedSamples]) { $1 }
        }
        self.statsReport.endTimer("mix.audio.mix")
        self.samples = result
        let output = AudioSample(buffers,
                         frequency: self.sampleRate,
                         channels: self.channelCount,
                         format: self.outputFormat,
                         sampleCount: Int(rescale(self.frameDuration, Int64(self.sampleRate)).value),
                         time: at.time(),
                         pts: mixTimestamp - self.delay,
                         assetId: self.idAsset,
                         workspaceId: self.idWorkspace,
                         constituents: constituents,
                         eventInfo: self.statsReport)
       _ = self.emit(output)
    }

    // (Position, Gain)
    private func samplePosition(_ sample: AudioSample) -> (Vector2, Float) {
        let center = Vector3(0, 0, 1) * sample.transform
        let front = Vector3(0, 1, 1) * sample.transform
        let mag = front - center
        let gain = sqrt((mag.x*mag.x)+(mag.y*mag.y))
        return (Vector2(center.x, center.y), gain)
    }

    // return the gain for each channel for a given position and gain
    private func channelGains(_ position: (Vector2, Float)) -> [Float] {
        let channelCount = self.channelCount
        let dimensions = min(channelCount-1, 2)
        let theta = Float.pi*2.0 / Float(channelCount)
        let halfTheta = theta/2
        let gains = (0..<channelCount).map { idx -> Float in
            let pos = Vector2(cos(theta*Float(idx)+halfTheta), sin(theta*Float(idx)+halfTheta))
            let mag = pos - position.0
            switch dimensions {
            case 0:
                return position.1
            case 1:
                return smoothstep(0.0, 0.5, 1.0 - mag.x * 0.5) * position.1 // using a 1-D line, drop y component
            case 2:
                let distance = sqrt((mag.x*mag.x)+(mag.y*mag.y)) * 0.5
                return smoothstep(0.0, 0.5, 1.0 - distance) * position.1 // revisit this to properly model dropoff.
            default:
                return position.1
            }
        }
        return gains
    }

    private func applyMixS16(_ input: Data,
                             gain: [Float],
                             backing: inout Data,
                             backingStartOffset: Int,
                             inputStartOffset: Int) -> Int {
        guard inputStartOffset >= 0 &&
              inputStartOffset < input.count &&
              backingStartOffset >= 0 &&
              backingStartOffset < backing.count else {
                return -1
        }
        let inputSize = input.count
        let backingSize = backing.count
        let numberBytes = min(max(backingSize - backingStartOffset, 0), max(input.count - inputStartOffset, 0))
        input.withUnsafeBytes { inputPtr in
            guard let baseAddress = inputPtr.baseAddress else {
                return
            }

            // TODO: Use SSE
            backing.withUnsafeMutableBytes { backingPtr in
                let ptr = backingPtr.bindMemory(to: Int16.self)
                let inptr = UnsafeRawPointer(baseAddress).bindMemory(to: Int16.self, capacity: inputSize / 2)
                let channelCount = gain.count
                for idx in 0..<(numberBytes/2) {
                    let channel = idx % channelCount
                    let value = Int64(Float(inptr[idx +
                                (inputStartOffset/2)]) * gain[channel]) +
                                Int64(ptr[idx + (backingStartOffset/2)])
                    ptr[idx + (backingStartOffset/2)] = Int16(max(Int64(Int16.min), min(Int64(Int16.max), value)))
                }
            }
        }
        return numberBytes
    }
    private var samples: [String: [AudioSample]]
    private var sourceOffset: [String: TimePoint]
    private var pts: TimePoint
    private let statsReport: StatsReport
    private let frameDuration: TimePoint
    private let delay: TimePoint
    private let epoch: TimePoint
    private let clock: Clock
    private let queue: DispatchQueue
    private let sampleRate: Int
    private let channelCount: Int
    private let outputFormat: AudioFormat
    private let idAsset: String
    private let idWorkspace: String
}

func smoothstep<T: BinaryFloatingPoint>(_ edge0: T, _ edge1: T, _ val: T) -> T {
    let val = clamp(0.0, 1.0, (val - edge0) / (edge1 - edge0))
    return val * val * (3 - 2 * val)
}

func clamp<T: BinaryFloatingPoint>(_ lower: T, _ upper: T, _ val: T) -> T {
    return max(min(upper, val), lower)
}
