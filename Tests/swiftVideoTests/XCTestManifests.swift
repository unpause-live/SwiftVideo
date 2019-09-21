import XCTest

#if !os(macOS)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(sampleRateConversionTests.allTests),
        testCase(busTests.allTests),
        testCase(timePointTests.allTests),
        testCase(audioMixTests.allTests),
        testCase(rtmpTests.allTests),
        testCase(statsTests.allTests)
    ]
}
#endif