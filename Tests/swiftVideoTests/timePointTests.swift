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

// swiftlint:disable identifier_name
import XCTest
import Foundation
import SwiftVideo

final class timePointTests: XCTestCase {

    func rescaleTest() {
        let a = TimePoint(2987595, 30000)
        let b = TimePoint(9958650, 100000)
        let c = rescale(a, b.scale)
        XCTAssertEqual(c.value, b.value)
    }

    func greaterThanTest() {
        let a = TimePoint(2987595, 30000)
        let b = TimePoint(9955317, 100000)
        XCTAssertEqual(a > b, true)
        XCTAssertEqual(b > a, false)
    }
    func lessThanTest() {
        let a = TimePoint(2987595, 30000)
        let b = TimePoint(9955317, 100000)
        XCTAssertEqual(b < a, true)
        XCTAssertEqual(a < b, false)
    }
    func gteTest() {
        let a = TimePoint(2987595, 30000)
        let b = TimePoint(9955317, 100000)
        XCTAssertEqual(a >= b, true)
        XCTAssertEqual(b >= a, false)
    }
    func lteTest() {
        let a = TimePoint(2987595, 30000)
        let b = TimePoint(9955317, 100000)
        XCTAssertEqual(b <= a, true)
        XCTAssertEqual(a <= b, false)
    }
    func addTest() {
        let a = TimePoint(2987595, 30000)
        let b = TimePoint(9955317, 100000)
        let c = b + TimePoint(1000, 30000)
        XCTAssertEqual(a <= c, true)
        XCTAssertEqual(a >= c, true)
    }
    func subTest() {
        let a = TimePoint(2957595, 30000)
        let b = TimePoint(9855316, 100000) // (2957595-1000) * 10 / 3
        let c = a - TimePoint(1000, 30000)
        print("\(b.toString()) == \(c.toString())")
        XCTAssertEqual(c >= b, true)
        XCTAssertEqual(c <= b, true)
    }

    func minTest() {
        let a = TimePoint(2957595, 30000)
        let b = TimePoint(9855316, 100000)
        let c = min(a, b)
        XCTAssertTrue(c == b)
    }

    func maxTest() {
        let a = TimePoint(2957595, 30000)
        let b = TimePoint(9855316, 100000)
        let c = max(a, b)
        XCTAssertTrue(c == a)
    }

    static var allTests = [
        ("rescaleTest", rescaleTest),
        ("greaterThanTest", greaterThanTest),
        ("lessThanTest", lessThanTest),
        ("gteTest", gteTest),
        ("lteTest", lteTest),
        ("addTest", addTest),
        ("subTest", subTest)
    ]

}
