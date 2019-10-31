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
final class statsTests: XCTestCase {

    func statsTest() {
        let clock = StepClock(stepSize: TimePoint(1000, 30000))
        let stats = StatsReport(period: TimePoint(5000, 1000), clock: clock)

        while clock.current() <= TimePoint(10000, 1000) {
            stats.addSample("test", 1)
            _ = clock.step()
        }
        let report = stats.report()
        let json = """
        { \"name\": \"test\", \"period\": 5.00, \"type\": \"int\", \"median\": 1, \"mean\": 1.00000, \"peak\": 1, \"low\": 1, \"total\": 150,
          \"averagePerSecond\": 30.00000, \"count\": 150 }
        """
        guard let reportJson = report?.results["test.5.00"] else {
            XCTAssertTrue(false)
            fatalError("reportJson missing")
        }
        XCTAssertEqual(json, reportJson)
    }

    static var allTests = [
        ("statsTest", statsTest)
        ]
}
