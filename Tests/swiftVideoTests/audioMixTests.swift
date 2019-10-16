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

import XCTest
import Foundation
import SwiftVideo
import BrightFutures
import NIO
import NIOExtras

func gcd<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
    return rhs == 0 ? lhs : gcd(rhs, lhs % rhs)
}

func lcm<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
    let res = gcd(lhs, rhs)
    return res != 0 ? (lhs / res &* rhs) : 0
}

final class audioMixTests: XCTestCase {
    let duration = TimePoint(60 * 60 * 1000, 1000)

    private func recur(_ clock: Clock, _ at: TimePoint, _ fn: @escaping (TimePoint) -> TimePoint) {
        let time = fn(at)
        clock.schedule(time) { [weak self] evt in
            self?.recur(clock, evt.time(), fn)
        }
    }

    private func runner(_ clock: Clock,
                        _ frameDuration: TimePoint,
                        _ audioPacketDuration: TimePoint,
                        _ receiver: Terminal<AudioSample>,
                        _ generator: @escaping (TimePoint) -> EventBox<AudioSample>,
                        delay: TimePoint = TimePoint(0, 48000),
                        latePacketProb: Float = 0.0) {
        let mixer = AudioMixer(clock,
            workspaceId: "test",
            frameDuration: frameDuration,
            sampleRate: 48000,
            channelCount: 2,
            delay: delay)
        let tx = mixer >>> receiver
        recur(clock, TimePoint(0, 48000)) { time in
            let sample = generator(time)
            _ = sample >>- mixer
            let value = Int.random(in: 0..<1000)
            let scheduleLate = value < Int(1000.0 * latePacketProb)
            return time + audioPacketDuration + (scheduleLate ? audioPacketDuration/2*3 : TimePoint(0, 48000))
        }
        print("first step")
        clock.step()
        while clock.current() < duration {
            sleep(1)
            print("clock.current = \(clock.current().toString())")
        }
    }

    func silenceTest() {
        let audioPacketDuration = TimePoint(1024, 48000)
        let frameDuration = TimePoint(960, 48000)
        let clock = StepClock(stepSize: frameDuration)
        let blank = Data(count: Int(audioPacketDuration.value) * 2 * 2) // 2-ch, 16-bit
        let reference = Data(count: Int(frameDuration.value) * 2 * 2)

        let receiver = Terminal<AudioSample> { sample in
            guard reference == sample.data()[0] else {
                fatalError("reference != sample.data()")
            }
            guard clock.current() == sample.pts() else {
                fatalError("clock.current() != pts \(clock.current().toString()) \(sample.pts().toString())")
            }
            clock.step()
            return .nothing(nil)
        }

        let generator: (TimePoint) -> EventBox<AudioSample> = { pts in
            let buffers = [blank]
            let sample = AudioSample(buffers,
                frequency: 48000,
                channels: 2,
                format: .s16i,
                sampleCount: Int(audioPacketDuration.value),
                time: clock.current(),
                pts: pts,
                assetId: "blank",
                workspaceId: "test")
            return .just(sample)
        }

        runner(clock, frameDuration, audioPacketDuration, receiver, generator)
    }

    func discontinuityTest() {
        let delay = TimePoint(0, 48000)
        let audioPacketDuration = TimePoint(1024, 48000)
        let discontinuityDuration = audioPacketDuration / 2 * 3
        let frameDuration = TimePoint(960, 48000)
        var discontinuityCount = 0
        var startOffset = 0
        var discontinuityEndTs: TimePoint?
        var discontinuityIndex: Int?
        // need to make a sine pattern of numberBuffers * 1024 samples in duration at (sample rate / frame duration) Hz
        let numberBuffers = lcm(audioPacketDuration.value, frameDuration.value) / audioPacketDuration.value
        let sineFreq = Int(frameDuration.scale / frameDuration.value)
        let baseBuffers: [Data] = (0..<numberBuffers).map { index in
            let pos = Int(index * audioPacketDuration.value)
            let wave = makeSine(pos, Int(audioPacketDuration.value), sineFreq, 48000)
            var buf = Data(capacity: Int(audioPacketDuration.value) * 2 * 2)
            for sample in wave {
                let bytes = buffer.toByteArray(sample)
                buf.append(contentsOf: bytes) // left
                buf.append(contentsOf: bytes) // right
            }
            return buf
        }

        let clock = StepClock(stepSize: frameDuration)
        var reference = Data(capacity: Int(frameDuration.value) * 4 * 2)
        makeSine(0, Int(frameDuration.value * 2), sineFreq, 48000).forEach { sample in
            let bytes = buffer.toByteArray(sample)
            reference.append(contentsOf: bytes) // left
            reference.append(contentsOf: bytes) // right
        }
        var pushIdx = 0
        var isFirst = true
        let receiver = Terminal<AudioSample> { sample in
            defer {
                clock.step()
            }
            guard isFirst == false && sample.pts().value > 0 else {
                isFirst = false
                return .nothing(nil)
            }
            guard let constituents = sample.constituents(),
                constituents.count > 0 else {
                //print("detected discontinuity \(sample.constituents())")
                return .nothing(nil)
            }
            let constituent = constituents[0]
            let sampleOffset = Int(constituent.normalizedPts.value - sample.pts().value) * 2 * 2

            if let discontinuityEnd = discontinuityEndTs, 
                let index = discontinuityIndex, discontinuityEnd <= constituent.pts {
                discontinuityCount += 1
                discontinuityIndex = nil
                discontinuityEndTs = nil
                //print("actual \(index) push \(pushIdx)")
                let offIdx1 = (((15 + index) % 15) * 1024) % 960
                let offIdx2 = (((15 + index + 1) % 15) * 1024) % 960
                let testOffset1 = offIdx1 * 2 * 2
                let testOffset2 = offIdx2 * 2 * 2
                // There's a race condition here so it could be one or the other 
                // depending on when the dispatchqueue in the mixer runs
                // more work would need to be done to make this deterministic
                let similarity1 = self.diff(reference,
                    sample.data()[0],
                    lhsStart: testOffset1,
                    rhsStart: sampleOffset,
                    count: Int(constituent.duration.value * 2 * 2))
                let similarity2 = self.diff(reference,
                    sample.data()[0],
                    lhsStart: testOffset2,
                    rhsStart: sampleOffset,
                    count: Int(constituent.duration.value * 2 * 2))
                startOffset = similarity1 > similarity2 ? testOffset1 : testOffset2
            }
            let similarity = self.diff(reference,
                sample.data()[0],
                lhsStart: startOffset,
                rhsStart: sampleOffset,
                count: Int(constituent.duration.value * 2 * 2))
            if sampleOffset > 0 {
                startOffset += (3840 - sampleOffset)
            }
            guard similarity > 0.9 else { // some small differences may be present due to floating point conversion
                print("const normalized pts \(constituent.normalizedPts.toString())")
                print("offsets: ref \(startOffset) \(discontinuityCount) buffs: \(numberBuffers) sample: \(sampleOffset) duration \(constituent.duration.value)")
                print("Error count: \(constituent.duration.value * 2 * 2) pts \(sample.pts().toString()) constituent \(constituent.pts.toString())")
                //try! reference.write(to: URL(string: "file:///home/james/dev/reference.pcm")!)
                //try! sample.data()[0].write(to: URL(string: "file:///home/james/dev/sample.pcm")!)
                fatalError("reference != sample.data() [\(similarity)]")
            }
            let targetPts = (clock.current() - delay)
            guard targetPts == sample.pts() else {
                fatalError("targetPts != pts \(targetPts.toString()) != \(sample.pts().toString())")
            }
            return .nothing(nil)
        }
        var currentTimestamp: TimePoint = TimePoint(0, 48000)
        let generator: (TimePoint) -> EventBox<AudioSample> = { pts in
            let buffers = [baseBuffers[pushIdx]]
            defer {
                pushIdx = (pushIdx + 1) % baseBuffers.count
            }
            let sample = AudioSample(buffers,
                frequency: 48000,
                channels: 2,
                format: .s16i,
                sampleCount: Int(audioPacketDuration.value),
                time: clock.current(),
                pts: pts,
                assetId: "blank",
                workspaceId: "test")
            if pts - currentTimestamp > audioPacketDuration {
                // First sample after discontinuity
                //print("discontinuity predicted end: pts=\(pts.toString()) currentTimestamp = \(currentTimestamp.toString())")
                discontinuityEndTs = pts
                discontinuityIndex = pushIdx
            }
            currentTimestamp = pts
            //print("sending \(pts.toString()) [\(pushIdx)]")
            return .just(sample)
        }

        runner(clock, frameDuration, audioPacketDuration, receiver, generator, delay: delay, latePacketProb: 0.01)
    }

    func delayTest() {
        singleSineImpl(delay: TimePoint(1920, 48000))
    }

    private func makeSine(_ idx: Int, _ count: Int, _ frequency: Int, _ sampleRate: Int, amplitude: Float = 1.0) -> [Int16] {
        var result = [Int16]()
        let freq = Float(frequency)
        let sampleRate = Float(sampleRate)
        for i in idx..<(idx+count) {
            let pos = Float(i)
            let val = Int16(sin(pos * Float.twoPi * freq / sampleRate) * Float(Int16.max) * amplitude)
            result.append(val)
        }
        return result
    }

    func singleSineTest() {
        singleSineImpl()
    }

    func singleSineImpl(delay: TimePoint = TimePoint(0, 48000)) {
        let audioPacketDuration = TimePoint(1024, 48000)
        let frameDuration = TimePoint(960, 48000)
        // need to make a sine pattern of numberBuffers * 1024 samples in duration at (sample rate / frame duration) Hz
        let numberBuffers = lcm(audioPacketDuration.value, frameDuration.value) / audioPacketDuration.value
        let sineFreq = Int(frameDuration.scale / frameDuration.value)
        let baseBuffers: [Data] = (0..<numberBuffers).map { index in
            let pos = Int(index * audioPacketDuration.value)
            let wave = makeSine(pos, Int(audioPacketDuration.value), sineFreq, 48000)
            var buf = Data(capacity: Int(audioPacketDuration.value) * 2 * 2)
            for sample in wave {
                let bytes = buffer.toByteArray(sample)
                buf.append(contentsOf: bytes) // left
                buf.append(contentsOf: bytes) // right
            }
            return buf
        }

        let clock = StepClock(stepSize: frameDuration)
        var reference = Data(capacity: Int(frameDuration.value) * 2 * 2)
        makeSine(0, Int(frameDuration.value), sineFreq, 48000).forEach { sample in
            let bytes = buffer.toByteArray(sample)
            reference.append(contentsOf: bytes) // left
            reference.append(contentsOf: bytes) // right
        }
        var pushIdx = 0
        var isFirst = true
        let receiver = Terminal<AudioSample> { sample in
            guard isFirst == false && sample.pts().value > 960 else {
                isFirst = false
                clock.step()
                return .nothing(nil)
            }
            let similarity = self.diff(reference, sample.data()[0])
            guard similarity > 0.9 else { // some small differences may be present due to floating point conversion
                print("error at timePoint \(sample.pts().toString()) \(pushIdx)")
                try! reference.write(to: URL(string: "file:///home/james/dev/reference.pcm")!)
                try! sample.data()[0].write(to: URL(string: "file:///home/james/dev/sample.pcm")!)
                fatalError("reference != sample.data() [\(similarity)]")
            }
            let targetPts = (clock.current() - delay)
            guard targetPts == sample.pts() else {
                fatalError("targetPts != pts \(targetPts.toString()) != \(sample.pts().toString())")
            }
            clock.step()
            return .nothing(nil)
        }

        let generator: (TimePoint) -> EventBox<AudioSample> = { pts in
            let buffers = [baseBuffers[pushIdx]]
            pushIdx = (pushIdx + 1) % baseBuffers.count
            let sample = AudioSample(buffers,
                frequency: 48000,
                channels: 2,
                format: .s16i,
                sampleCount: Int(audioPacketDuration.value),
                time: clock.current(),
                pts: pts,
                assetId: "blank",
                workspaceId: "test")
            return .just(sample)
        }

        runner(clock, frameDuration, audioPacketDuration, receiver, generator, delay: delay)
    }

    func twoSineTest() {
        let audioPacketDuration = TimePoint(1024, 48000)
        let frameDuration = TimePoint(960, 48000)
        // need to make a sine pattern of numberBuffers * 1024 samples in duration at (sample rate / frame duration) Hz
        let numberBuffers = lcm(audioPacketDuration.value, frameDuration.value) / audioPacketDuration.value
        let sineFreq = Int(frameDuration.scale / frameDuration.value)
        let baseBuffers: [Data] = (0..<numberBuffers).map { index in
            let pos = Int(index * audioPacketDuration.value)
            let wave = makeSine(pos, Int(audioPacketDuration.value), sineFreq, 48000, amplitude: 0.5)
            let wave2 = makeSine(pos, Int(audioPacketDuration.value), sineFreq * 2, 48000, amplitude: 0.5)
            var buf = Data(capacity: Int(audioPacketDuration.value) * 2 * 2)
            for sample in zip(wave, wave2) {
                let bytes = buffer.toByteArray(sample.0 + sample.1)
                buf.append(contentsOf: bytes) // left
                buf.append(contentsOf: bytes) // right
            }
            return buf
        }

        let clock = StepClock(stepSize: frameDuration)
        var reference = Data(capacity: Int(frameDuration.value) * 2 * 2)
        zip(makeSine(0, Int(frameDuration.value), sineFreq, 48000, amplitude: 0.5),
            makeSine(0, Int(frameDuration.value), sineFreq * 2, 48000, amplitude: 0.5)).forEach { sample in
            let bytes = buffer.toByteArray(sample.0 + sample.1)
            reference.append(contentsOf: bytes) // left
            reference.append(contentsOf: bytes) // right
        }
        var pushIdx = 0
        var isFirst = true
        let receiver = Terminal<AudioSample> { sample in
            guard isFirst == false && sample.pts().value > 0 else {
                isFirst = false
                clock.step()
                return .nothing(nil)
            }
            let similarity = self.diff(reference, sample.data()[0])
            guard similarity > 0.9 else { // some small differences may be present due to floating point conversion
                print("error at timePoint \(sample.pts().toString()) \(pushIdx)")
                try! reference.write(to: URL(string: "file:///home/james/dev/reference.pcm")!)
                try! sample.data()[0].write(to: URL(string: "file:///home/james/dev/sample.pcm")!)
                fatalError("reference != sample.data() [\(similarity)]")
            }
            let targetPts = clock.current()
            guard targetPts == sample.pts() else {
                fatalError("targetPts != pts \(targetPts.toString()) != \(sample.pts().toString())")
            }
            clock.step()
            return .nothing(nil)
        }

        let generator: (TimePoint) -> EventBox<AudioSample> = { pts in
            let buffers = [baseBuffers[pushIdx]]
            pushIdx = (pushIdx + 1) % baseBuffers.count
            let sample = AudioSample(buffers,
                frequency: 48000,
                channels: 2,
                format: .s16i,
                sampleCount: Int(audioPacketDuration.value),
                time: clock.current(),
                pts: pts,
                assetId: "blank",
                workspaceId: "test")
            return .just(sample)
        }

        runner(clock, frameDuration, audioPacketDuration, receiver, generator)
    }

    private func diff(_ lhs: Data, _ rhs: Data, lhsStart: Int = 0, rhsStart: Int = 0, count: Int = Int.max) -> Float {
        let byteCount = min(min(lhs.count - lhsStart, rhs.count - rhsStart), count)
        var diffs = 0
        for i in 0..<byteCount {
            if lhs[i+lhsStart] != rhs[i+rhsStart] {
                diffs += 1
            }
        }
        return Float(byteCount - diffs) / Float(byteCount)
    }
    static var allTests = [
        ("silenceTest", silenceTest),
        ("singleSineTest", singleSineTest),
        ("twoSineTest", twoSineTest),
        ("discontinuityTest", discontinuityTest),
        ("delayTest", delayTest)
    ]
}
