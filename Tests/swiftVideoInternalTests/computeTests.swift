#if !DISABLE_INTERNAL
import XCTest
import Foundation
import CSwiftVideo
@testable import SwiftVideo

// swiftlint:disable:next type_name
final class computeTests: XCTestCase {
    func defaultKernelSearch() {
        let kernels = [
            "img_nv12_nv12",
            "img_bgra_nv12",
            "img_rgba_nv12",
            "img_bgra_bgra",
            "img_y420p_y420p",
            "img_y420p_nv12",
            "img_clear_nv12",
            "img_clear_yuvs",
            "img_clear_bgra",
            "img_clear_rgba",
            "img_rgba_y420p",
            "img_bgra_y420p",
            "img_clear_y420p"
            ]
        kernels.forEach {
            do {
                let result = try defaultComputeKernelFromString($0)
                // img_clear_rgba uses img_clear_bgra
                if $0 != "img_clear_rgba" {
                    XCTAssertEqual($0, String(describing: result))
                } else {
                    XCTAssertEqual("img_clear_bgra", String(describing: result))
                }
            } catch {
                print("Caught error \(error)")
                XCTAssertEqual(0, 1)
            }
       }
    }
    static var allTests = [
        ("defaultKernelSearch", defaultKernelSearch)
    ]
}
#endif
