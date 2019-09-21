import XCTest
import Foundation
import SwiftVideo
import CSwiftVideo

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