import XCTest
import SwiftVideo

private func makeSine(_ idx: Int,
                      _ count: Int,
                      _ frequency: Int,
                      _ sampleRate: Int,
                      amplitude: Float = 1.0) -> [Int16] {
    var result = [Int16]()
    let freq = Float(frequency)
    let sampleRate = Float(sampleRate)
    for idx in idx..<(idx+count) {
        let pos = Float(idx)
        let val = Int16(sin(pos * Float.twoPi * freq / sampleRate) * Float(Int16.max) * amplitude)
        result.append(val)
    }
    return result
}

final class audioSegmenterTests: XCTestCase {
    let duration = TimePoint(60 * 60 * 1000, 1000)

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
                        latePacketProb: Float = 0.0) {
        let segmenter = AudioPacketSegmenter(frameDuration)
        let txn = segmenter |>> receiver
        recur(clock, TimePoint(0, 48000)) { time in
            let sample = generator(time)
            let result = sample >>- txn
            print("result=\(result)")
            let value = Int.random(in: 0..<1000)
            let scheduleLate = value < Int(1000.0 * latePacketProb)
            return time + audioPacketDuration + (scheduleLate ? audioPacketDuration/2*3 : TimePoint(0, 48000))
        }
        print("first step")
        clock.step()
        while clock.current() < duration {
            sleep(1)
            print("clock.current = \(clock.current().toString())")
            //clock.step()
        }
    }

    func segmenterTest() {
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
            print("received sample")
            //dump(sample)
            clock.step()
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
            let targetPts = clock.current()
            guard targetPts == sample.pts() else {
                fatalError("targetPts != pts \(targetPts.toString()) != \(sample.pts().toString())")
            }
            //clock.step()
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
    static var allTests = [
        ("segmenterTest", segmenterTest)
    ]
}
