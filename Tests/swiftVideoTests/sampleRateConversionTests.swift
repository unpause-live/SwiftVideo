import XCTest
import Foundation
import SwiftVideo


final class sampleRateConversionTests: XCTestCase {
    
    func sampleCountTest() {
        let audioPacketDuration = TimePoint(1024, 44100)
        let src = AudioSampleRateConversion(48000, 2, .s16i)
        let blank = Data(count: Int(audioPacketDuration.value) * 4) // 1-ch, 32-bit float
        let buffers = [blank]

        let clock = StepClock(stepSize: audioPacketDuration)
        var pts = TimePoint(0, 44100)
        var newPts = TimePoint(0, 48000)
        let tx = src >>> Terminal<AudioSample> { sample in
            XCTAssertEqual(newPts.scale, sample.pts().scale)
            XCTAssertEqual(newPts.value, sample.pts().value)
            newPts.value += Int64(sample.numberSamples())
            return .nothing(sample.info())
        }

        for i in 0..<100000 {
            let sample = AudioSample(buffers, 
                frequency: 44100, 
                channels: 1, 
                format: .f32p, 
                sampleCount: Int(audioPacketDuration.value),
                time: clock.current(),
                pts: pts,
                assetId: "blank",
                workspaceId: "test");

            .just(sample) >>- tx
            pts = pts + audioPacketDuration
            clock.step()
        }
        
    }

    static var allTests = [
        ("sampleCountTest", sampleCountTest)
    ]
}