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

public typealias XCTestCaseClosure = (XCTestCase) throws -> Void

final class rtmpTests: XCTestCase {

#if os(Linux)
    required override init(name: String, testClosure: @escaping XCTestCaseClosure) {
        let stepSize = TimePoint(16, 1000)
        let clock = StepClock(stepSize: stepSize)
        self.stepSize = stepSize
        self.sampleInfo = [(TimePoint, Int)]()
        self.rtmp = nil
        self.clock = clock
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        self.quiesce = ServerQuiescingHelper(group: group)
        self.buffers = [1009, 2087, 1447, 2221, 2503, 3001, 4999, 2857, 9973, 8191, 7331, 3539, 44701, 47701, 65537, 65701, 99989, 99991, 111323].map {
            var data = Data(count: $0)
            data[4] = 0x5
            return data
        }
        self.currentTs = TimePoint(0, 1000)
        super.init(name: name, testClosure: testClosure)
    }

    func setupRtmp() {
        let bufferSize = TimePoint(0, 1000)
        let stepSize = TimePoint(16, 1000)
        self.rtmp = Rtmp(self.clock, bufferSize: bufferSize, onEnded: { _ in () }) { [weak self] pub, sub in
            if let pub = pub as? Terminal<CodedMediaSample>, let strongSelf = self {
                strongSelf.publish = pub
                strongSelf.clock.schedule(strongSelf.currentTs) { [weak self] in
                    strongSelf.push($0.time())
                }
                strongSelf.sampleInfo.remove(at: 0) // remove first sample that is not sent
                for _ in 0...12 {
                    strongSelf.clock.step()
                }
                strongSelf.clock.schedule(strongSelf.currentTs) { [weak self] in
                    strongSelf.push($0.time())
                }
                let iterations = bufferSize.value / stepSize.value
                for _ in 0...(iterations+1) {
                    strongSelf.clock.schedule(strongSelf.currentTs + stepSize) { [weak self] in
                        strongSelf.push($0.time())
                    }
                    strongSelf.clock.step()
                }
            }
            if let sub = sub as? Source<CodedMediaSample> {
                self?.subscribe = sub

                self?.stx = sub >>> Tx { [weak self] in
                    self?.recv($0)

                    return .nothing($0.info())
                }
            }
            return Future { $0(.success(true)) }
        }
    }

    func rtmpTest(_ port: Int, _ duration: TimePoint, offset: TimePoint = TimePoint(0, 1000)) {
        currentTs = TimePoint(0, 1000)
        self.clock.reset()
        self.setupRtmp()
        let start = currentTs
        let end = start + duration
        self.offset = offset
        _ = rtmp?.serve(host: "0.0.0.0", port: port, quiesce: self.quiesce, group: self.group)
        rtmp?.connect(url: URL(string: "rtmp://localhost:\(port)/hi/hello")!, publishToPeer: true, group: self.group, workspaceId: "test", assetId: "test")
        let wallClock = WallClock()

        while(currentTs < end) {
            let currentReal = seconds(wallClock.current())
            let currentProgress = seconds(currentTs - start)
            let rate = currentProgress / currentReal
            let progress = currentProgress / seconds(end)
            print("[\(rate)x] progress: \(progress * 100)%")
            sleep(1)
        }
        self.subscribe = nil
        self.publish = nil
        self.sampleInfo.removeAll(keepingCapacity: true)
        self.stx = nil
        self.rtmp = nil
        //sleep(1)
    }

    func basicTest() {
        let duration = TimePoint(60 * 5 * 1000, 1000)
        rtmpTest(5001, duration)
    }

    func extendedTimestampTest() {
        let offset = TimePoint(16777216, 1000)
        let duration = TimePoint(60 * 5 * 1000, 1000)
        rtmpTest(5002, duration, offset: offset)
    }

    func rolloverTest() {
        let offset = TimePoint(4294966296, 1000)
        let duration = TimePoint(60 * 5 * 1000, 1000)
        rtmpTest(5003, duration, offset: offset)
    }

    private func push(_ time: TimePoint) {
        guard let pub = publish else {
            return
        }
        self.currentTs = time
        let idx = Int.random(in: 0..<buffers.count)
        let pts = time + self.offset
        self.sampleInfo.append((pts, idx))
        currentIndex = idx
        let sample = CodedMediaSample("test", "test", time, pts, nil, .video, .avc, buffers[idx], ["config": Data(count: 48)], "test")
        let result = .just(sample) >>- pub
    }

    private func recv(_ sample: CodedMediaSample) {
        guard self.sampleInfo.count > 0 else {
            print("sampleinfo == 0")
            return
        }
        let (pts, idx) = self.sampleInfo[0]
        if sample.pts() != pts {
            fatalError("got packet pts=\(sample.pts().toString()) expected=\(pts.toString())")
        }
        if sample.data() != buffers[idx] {
            fatalError("buffers dont match")
        }
        self.sampleInfo.remove(at: 0)

        self.clock.schedule(self.currentTs + self.stepSize) { [weak self] in
            self?.push($0.time())
        }
        self.clock.step()
    }

    static var allTests = [
        ("extendedTimestampTest", extendedTimestampTest),
        ("basicTest", basicTest),
        ("rolloverTest", rolloverTest)
    ]
    var offset = TimePoint(0, 1000)
    var sampleInfo: [(TimePoint, Int)]
    let buffers: [Data]
    let stepSize: TimePoint
    var currentIndex: Int = 0
    var currentTs: TimePoint
    var shouldExit: Bool = false
    var rtmp: Rtmp?
    let clock: StepClock
    let group: EventLoopGroup
    let quiesce: ServerQuiescingHelper
    var publish: Terminal<CodedMediaSample>?
    var subscribe: Source<CodedMediaSample>?
    var stx: Tx<CodedMediaSample, CodedMediaSample>?
#else
    static var allTests: [(String, XCTestCaseClosure)] = []
#endif
}
