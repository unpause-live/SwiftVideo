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

import Foundation
import Dispatch

public protocol Clock {
    func step() -> TimePoint
    func current() -> TimePoint
    func schedule(_ at: TimePoint, f: @escaping (ClockTickEvent) -> Void)
    func fromUnixTime(_ time: Int64) -> TimePoint /* Base 100k */
    func toUnixTime(_ time: TimePoint) -> Int64
}

public final class WallClock: Clock {
    private let epoch: Date
    private let assetId: String
    private let workspaceId: String

    public func step() -> TimePoint {
        return current()
    }

    public func current() -> TimePoint {
        return TimePoint(Date().timeIntervalSince(epoch))
    }

    public func fromUnixTime(_ time: Int64) -> TimePoint {
        let seconds = Double(time) / 100000.0
        let dt = Date(timeIntervalSince1970: seconds)
        return TimePoint(dt.timeIntervalSince(epoch))
    }

    public func toUnixTime(_ time: TimePoint) -> Int64 {
        let secs = Double(seconds(time))
        let dt = Int64((epoch + secs).timeIntervalSince1970 * 100000.0)
        return dt
    }

    public init(assetId: String = UUID().uuidString,
                workspaceId: String = "wallclock") {
        self.epoch = Date()
        self.assetId = assetId
        self.workspaceId = workspaceId
    }

    public init(_ epoch: Date,
                assetId: String = UUID().uuidString,
                workspaceId: String = "wallclock") {
        self.epoch = epoch
        self.assetId = assetId
        self.workspaceId = workspaceId
    }

    public func schedule(_ at: TimePoint, f: @escaping (ClockTickEvent) -> Void) {
        let cur = current()
        if at <= cur {
            f(ClockTickEvent(at, self.assetId, self.workspaceId))
        } else {
            let t = at - cur
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(seconds(t))) {
                f(ClockTickEvent(at, self.assetId, self.workspaceId))
            }
        }
    }
}

public final class StepClock: Clock {
    private var time = TimePoint(0)
    private let stepSize: TimePoint
    private var scheduled = [(TimePoint, (ClockTickEvent) -> Void)]()
    private let assetId: String
    private let workspaceId: String
    private let queue: DispatchQueue
    public init(stepSize: TimePoint,
                assetId: String = UUID().uuidString,
                workspaceId: String = "stepclock") {
        self.stepSize = stepSize
        self.assetId = assetId
        self.workspaceId = workspaceId
        self.queue = DispatchQueue(label: "stepclock.\(assetId))")
    }

    @discardableResult
    public func step() -> TimePoint {
        // swiftlint:disable:next shorthand_operator
        self.time = self.time + self.stepSize
        return runEvents()
    }

    public func current() -> TimePoint {
        return self.time
    }

    public func fromUnixTime(_ time: Int64) -> TimePoint {
        return current()
    }

    public func toUnixTime(_ time: TimePoint) -> Int64 {
        return 0
    }

    public func reset() {
        self.time = TimePoint(0)
        self.queue.async {
            self.scheduled.removeAll(keepingCapacity: true)
        }
    }

    public func schedule(_ at: TimePoint, f: @escaping (ClockTickEvent) -> Void) {
        let cur = current()
        if at <= cur {
            f(ClockTickEvent(at, self.assetId, self.workspaceId))
        } else {
            self.queue.async {
                self.scheduled.append((at, f))
            }
        }
    }

    func runEvents() -> TimePoint {
        let cur = current()
        self.queue.sync {
            let scheduled = self.scheduled
            self.scheduled.removeAll(keepingCapacity: true)
            let filtered = scheduled.filter { (at, fun) in
                if at <= cur {
                    fun(ClockTickEvent(at, self.assetId, self.workspaceId))
                    return false
                }
                return true
            }
            self.scheduled += filtered
        }
        return cur
    }
}

//
//
// See Proto/TimePoint.proto
extension TimePoint: Comparable {
    public init(_ value: Int64, _ scale: Int64) {
        self.value = value
        self.scale = scale
    }
    public init(_ value: Double) {
        self.value = Int64(value * 100000)
        self.scale = 100000
    }
    public func toString() -> String {
        return "\(self.value)/\(self.scale)"
    }
}

func gcd<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
    return rhs == 0 ? lhs : gcd(rhs, lhs % rhs)
}

func lcm<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
    let res = gcd(lhs, rhs)
    return res != 0 ? (lhs / res &* rhs) : 0
}

func simplify<T: FixedWidthInteger>(_ num: T, _ den: T) -> (T, T) {
    let div = gcd(num, den)
    return (num/div, den/div)
}

public func simplify(_ time: TimePoint) -> TimePoint {
    let (num, den) = simplify(time.value, time.scale)
    return TimePoint(num, den)
}

public func rescale(_ time: TimePoint, _ scale: Int64) -> TimePoint {
    if time.scale != scale && scale > 0 && time.scale > 0 {
        let cscale = lcm(scale, time.scale)
        let lmul = cscale / time.scale
        let rmul = cscale / scale
        let (num, den) = (lmul &* time.value / (rmul == 0 ? 1 : rmul), scale)
        return TimePoint(num, den)
    } else {
        return time
    }
}

public func > (lhs: TimePoint, rhs: TimePoint) -> Bool {
    let res = rescale(lhs, rhs.scale)
    return res.value > rhs.value
}

public func < (lhs: TimePoint, rhs: TimePoint) -> Bool {
    let res = rescale(lhs, rhs.scale)
    return res.value < rhs.value
}

public func >= (lhs: TimePoint, rhs: TimePoint) -> Bool {
    return !(lhs < rhs)
}

public func <= (lhs: TimePoint, rhs: TimePoint) -> Bool {
    return !(lhs > rhs)
}

public func - (lhs: TimePoint, rhs: TimePoint) -> TimePoint {
    let res = rescale(lhs, rhs.scale)
    return TimePoint(res.value &- rhs.value, rhs.scale)
}

public func + (lhs: TimePoint, rhs: TimePoint) -> TimePoint {
    let res = rescale(lhs, rhs.scale)
    return TimePoint(res.value &+ rhs.value, rhs.scale)
}

public func * (lhs: TimePoint, rhs: Int64) -> TimePoint {
    return TimePoint(lhs.value &* rhs, lhs.scale)
}

public func % (lhs: TimePoint, rhs: TimePoint) -> TimePoint {
    let res = rescale(lhs, rhs.scale)
    return rhs.value != 0 ? TimePoint(res.value % rhs.value, rhs.scale) : TimePoint(0, rhs.scale)
}

public func / (lhs: TimePoint, rhs: Int64) -> TimePoint {
    return TimePoint(lhs.value / rhs, lhs.scale)
}

public func seconds(_ time: TimePoint) -> Float {
    return Float(time.value) / Float(time.scale)
}

public func fseconds(_ time: TimePoint) -> Double {
    return Double(time.value) / Double(time.scale)
}

public func min(_ lhs: TimePoint, _ rhs: TimePoint) -> TimePoint {
    return lhs < rhs ? lhs : rhs
}

public func max(_ lhs: TimePoint, _ rhs: TimePoint) -> TimePoint {
    return lhs > rhs ? lhs : rhs
}

public func clamp(_ val: TimePoint, _ low: TimePoint, _ high: TimePoint) -> TimePoint {
    return min(max(val, low), high)
}

public class ClockTickEvent: Event {
    let timePoint: TimePoint
    let idAsset: String
    let idWorkspace: String
    init(_ time: TimePoint, _ assetId: String, _ workspaceId: String) {
        self.timePoint = time
        self.idAsset = assetId
        self.idWorkspace = workspaceId
    }

    public func type() -> String { return "clock.tick" }
    public func time() -> TimePoint { return timePoint }
    public func assetId() -> String { return idAsset }
    public func workspaceId() -> String { return idWorkspace }
    public func workspaceToken() -> String? { return nil }
    public func info() -> EventInfo? { return nil }
}
