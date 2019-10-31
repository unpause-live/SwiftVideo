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
import CSwiftVideo

// swiftlint:disable:next type_name
final class busTests: XCTestCase {

    struct TestEvent: Event {
        func type() -> String {
            return "test"
        }
        func time() -> TimePoint {
            return TimePoint(0, 1000)
        }
        func assetId() -> String {
            return "assetId"
        }
        func workspaceId() -> String {
            return "workspaceId"
        }
        func workspaceToken() -> String? {
            return "workspaceToken"
        }
        func info() -> EventInfo? {
            return nil
        }
        init(_ idx: Int) {
            self.idx = idx
        }
        let idx: Int
    }

    struct TestEvent2: Event {
        func type() -> String {
            return "test2"
        }
        func time() -> TimePoint {
            return TimePoint(0, 1000)
        }
        func assetId() -> String {
            return "assetId2"
        }
        func workspaceId() -> String {
            return "workspaceId2"
        }
        func workspaceToken() -> String? {
            return "workspaceToken2"
        }
        func info() -> EventInfo? {
            return nil
        }
    }

    func busDispatchTest() {
        let bus = Bus<TestEvent>()
        var count: Int = 0
        let tx: Tx<TestEvent, TestEvent> = Tx { event in
            XCTAssertEqual(event.idx, count)
            count += 1
            return .just(event)
        }
        let tx2: Tx<TestEvent, TestEvent> = Tx { _ in
            return .nothing(nil)
        }
        _ = bus <<| tx
        _ = bus <<| tx2
        for i in 0..<100 {
            _ = bus.append(.just(TestEvent(i)))
        }
        print("appended, waiting")
        sleep(3)
        XCTAssertEqual(count, 100)
    }

    func busFilterTest() {
        let bus = HeterogeneousBus()
        var count: Int = 0

        let tx: Tx<TestEvent, TestEvent> = Tx { event in
            XCTAssertEqual(event.idx, count)
            count += 1
            return .just(event)
        }
        let tx2: Tx<TestEvent2, TestEvent2> = Tx { _ in
            .nothing(nil)
        }
        let event2 = TestEvent2()
        let pipe: Tx<TestEvent, ResultEvent> = mix() >>> bus
        let pipe2: Tx<TestEvent2, ResultEvent> = mix() >>> bus
        let rcv = bus <<| filter() >>> tx
        let rcv2 = bus <<| filter() >>> tx2
        for i in 0..<100 {
            _ = .just(TestEvent(i)) >>- pipe
            _ = .just(event2) >>- pipe2
        }
        sleep(3)
        print("count = \(count)")
        XCTAssertEqual(count, 100)

    }

    func golombTest() {
        let result = test_golomb_dec()
        print("golombTest result=\(result)")
        XCTAssertEqual(result, 254)
    }

    static var allTests = [
        ("busDispatchTest", busDispatchTest),
        ("busFilterTest", busFilterTest),
        ("golombTest", golombTest)
    ]
}
