import Foundation

public struct StatsResult {
    public let assetId: String?
    public let eventTime: Date
    public let timePoint: TimePoint
    public let results: [String:String]
}
public class StatsReport {

    private class Samples {
        init() {
            doubleSamples = [:]
            timepointSamples = [:]
            intSamples = [:]
        }
        func clear() {
            doubleSamples.removeAll(keepingCapacity: true)
            timepointSamples.removeAll(keepingCapacity: true)
            intSamples.removeAll(keepingCapacity:true)
        }
        func merging(_ other: Samples) -> Samples {
            let result = Samples()
            result.doubleSamples = self.doubleSamples.merging(other.doubleSamples) { $0 + $1 }
            result.intSamples = self.intSamples.merging(other.intSamples) { $0 + $1 }
            result.timepointSamples = self.timepointSamples.merging(other.timepointSamples) { $0 + $1 }
            return result
        }
        var doubleSamples: [String: [Sample<Double>]]
        var timepointSamples: [String: [Sample<TimePoint>]]
        var intSamples: [String: [Sample<Int>]]
    }

    // Periods are the time periods that should be computed. Defaults to 1 second, 10 seconds, 30 seconds
    public init(assetId: String? = nil,
                period: TimePoint = TimePoint(5000, 1000),
                clock: Clock? = nil) {

        let clock = clock ?? WallClock()
        self.clock = clock
        self.idAsset = assetId
        self.inflightTimers = [String:TimePoint]()
        self.queue = DispatchQueue(label: "stats,\(UUID().uuidString)")
        self.epoch = clock.current()
        let now = clock.current()
        /*if periods.count == 0 {
            let periods = [TimePoint(5000,1000)] 
            self.periods = zip(periods, Array(repeating: now, count: periods.count)).map { ($0, $1) }
        } else {
            self.periods = zip(periods, Array(repeating: now, count: periods.count)).map { ($0, $1) }
        }*/
        self.period = period
        self.lastComputed = now

        self.samples = (0..<5).map { _ in Samples() }
        self.results = nil //[String:String]()
        self.clock.schedule(now + period) { [weak self] event in 
            guard let strongSelf = self else {
                return
            }
            strongSelf.queue.async {
                strongSelf.recompute(event.time())
            }
        }

    }

    public init(assetId: String?, other: StatsReport) {
        print("init other")
        self.clock = other.clock
        self.results = other.results
        self.idAsset = assetId
        self.queue = DispatchQueue(label: "stats,\(UUID().uuidString)")
        self.inflightTimers = other.inflightTimers
        self.samples = other.samples
        self.epoch = other.epoch
        self.period = other.period
        self.lastComputed = other.lastComputed
        self.clock.schedule(other.lastComputed + other.period) { [weak self] event in 
            guard let strongSelf = self else {
                return
            }
            strongSelf.queue.async {
                strongSelf.recompute(event.time())
            }
        }
    }

    public func merging(_ other: StatsReport) -> StatsReport {
        let report = StatsReport(assetId: other.assetId(), other: other)
        report.samples = zip(self.samples, other.samples).map { $0.merging($1) }
        return report
    }

    public func startTimer(_ name: String) {
        let now = clock.current()
        queue.async { [weak self] in 
            self?.inflightTimers[name] = now
        }
    }

    public func endTimer(_ name: String) {
        let end = clock.current()
        queue.async { [weak self] in 
            guard let start = self?.inflightTimers[name] else {
                return
            }
            
            let diff = end - start
            self?.inflightTimers.removeValue(forKey: name)
            self?.addSample(name, diff)
        }
    }

    public func addSample(_ name: String, _ val: Double) {
        let sampleTime = clock.current()
        let sampleIndex = bucketIndexForTime(sampleTime)
        self.queue.async { [weak self] in
            guard let strongSelf = self else {
                return
            }
            let currentSamples = strongSelf.samples[sampleIndex]
            if currentSamples.doubleSamples[name] == nil {
                currentSamples.doubleSamples[name] = [Sample<Double>]()
            }
            currentSamples.doubleSamples[name]?.append(Sample(sampleTime, val))
            //strongSelf.recompute(sampleTime)
        }
    }

    public func addSample(_ name: String, _ val: TimePoint) {
        let sampleTime = clock.current()
        let sampleIndex = bucketIndexForTime(sampleTime)
        self.queue.async { [weak self] in
            guard let strongSelf = self else {
                return
            }
            let currentSamples = strongSelf.samples[sampleIndex]
            if currentSamples.timepointSamples[name] == nil {
                currentSamples.timepointSamples[name] = [Sample<TimePoint>]()
            }
            currentSamples.timepointSamples[name]?.append(Sample(sampleTime, val))
            //strongSelf.recompute(sampleTime)
        }
    }

    func bucketIndexForTime(_ time: TimePoint) -> Int {
        let duration = rescale(self.period, time.scale)
        let now = time - rescale(self.epoch, time.scale)
        let bucketIdx = now.value / duration.value % Int64(self.samples.count)
        return Int(bucketIdx)
    }

    public func addSample(_ name: String, _ val: Int) {
        let sampleTime = clock.current()
        let sampleIndex = bucketIndexForTime(sampleTime)
        self.queue.async { [weak self] in
            guard let strongSelf = self else {
                return
            }

            let currentSamples = strongSelf.samples[sampleIndex]
            if currentSamples.intSamples[name] == nil {
                currentSamples.intSamples[name] = [Sample<Int>]()
            }
            currentSamples.intSamples[name]?.append(Sample(sampleTime, val))
            //strongSelf.recompute(sampleTime)
        }
    }

    public func report() -> StatsResult? {
        var res: StatsResult? = nil
        self.queue.sync {
            res = self.results
            self.results = nil
        }
        return res
    }

    public func assetId() -> String? {
        return idAsset
    }

    private func recompute(_ now: TimePoint) {
        defer {
            self.clock.schedule(now + self.period) { [weak self] event in 
                guard let strongSelf = self else {
                    return
                }
                strongSelf.queue.async {
                    strongSelf.recompute(event.time())
                }
            }
            self.lastComputed = now
        }
        let duration = self.period
        let sampleIndex = (self.samples.count + bucketIndexForTime(now) - 2) % self.samples.count
        let sampleTime = now - duration
        let currentSamples = self.samples[sampleIndex]
        let dResults = currentSamples.doubleSamples.reduce([String:String]()) { $0.merging(compute(sampleTime, $1.0, duration: duration, samples: $1.1)) { $1 } }
        let tResults = currentSamples.timepointSamples.reduce([String:String]()) { $0.merging(compute(sampleTime, $1.0, duration: duration, samples: $1.1)) { $1 } }
        let iResults = currentSamples.intSamples.reduce([String:String]()) { $0.merging(compute(sampleTime, $1.0, duration: duration, samples: $1.1)) { $1 } }
        let results: [String:String] = [dResults, tResults, iResults].reduce([:]) { $0.merging($1) { $1 } }
        self.results = StatsResult(assetId: self.assetId(),
            eventTime: Date() - TimeInterval(seconds(duration)), 
            timePoint: now - duration, 
            results: results)

        self.samples[sampleIndex].clear()
    }

    private func compute(_ now: TimePoint, _ name: String, duration: TimePoint, samples: [Sample<TimePoint>]) -> [String: String] {
        guard samples.count > 0 else {
            return [String:String]()
        }
        let sorted = samples.sorted { $0.time > $1.time }
        let olderThan = now - duration
        let idx = sorted.firstIndex(where:{ $0.time < olderThan }) ?? sorted.count
        guard idx > 0 else {
            return [String:String]()
        }
        let base = idx < sorted.count ? Array(sorted.prefix(upTo: idx)) : sorted
        let period = String(format: "%.2f", seconds(duration))
        let fullname = "\(name).\(period)"
        let byVal = base.sorted { $0.value < $1.value }
        let median = fseconds(byVal[byVal.count/2].value)
        let total = byVal.reduce(0.0) { $0 + fseconds($1.value) }
        let mean = total / Double(byVal.count)
        let peak = fseconds(byVal[byVal.count-1].value)
        let low = fseconds(byVal[0].value)
        let perPeriod = total / fseconds(duration)
        let report = String(format: """
        { \"name\": \"\(name)\", \"period\": \(period), \"type\": \"time\", \"median\": %.5f, \"mean\": %.5f, \"peak\": %.5f, \"low\": %.5f, \"total\": %.5f,
          \"averagePerSecond\": %.5f, \"count\": %d}
        """, median, mean, peak, low, total, perPeriod, byVal.count)
        return [fullname:report]
    }

    private func compute(_ now: TimePoint, _ name: String, duration: TimePoint, samples: [Sample<Double>]) -> [String: String] {
        guard samples.count > 0 else {
            return [String:String]()
        }
        let sorted = samples.sorted { $0.time > $1.time }
        let olderThan = now - duration
        let idx = sorted.firstIndex(where:{ $0.time < olderThan }) ?? sorted.count
        guard idx > 0 else {
            return [String:String]()
        }

        let base = idx < sorted.count ? Array(sorted.prefix(upTo: idx)) : sorted
        let period = String(format: "%.2f", seconds(duration))
        let fullname = "\(name).\(period)"
        let byVal = base.sorted { $0.value < $1.value }
        let median = byVal[byVal.count/2].value
        let total = byVal.reduce(0.0) { $0 + $1.value }
        let mean = total / Double(byVal.count)
        let peak = byVal[byVal.count-1].value
        let low = byVal[0].value
        let perPeriod = total / fseconds(duration)
        let report = String(format: """
        { \"name\": \"\(name)\", \"period\": \(period), \"type\": \"double\", \"median\": %.5f, \"mean\": %.5f, 
        \"peak\": %.5f, \"low\": %.5f, \"total\": %.5f,
          \"averagePerSecond\": %.5f, \"count\": %d }
        """, median, mean, peak, low, total, perPeriod, byVal.count)
        return [fullname:report]
    }

     private func compute(_ now: TimePoint, _ name: String, duration: TimePoint, samples: [Sample<Int>]) -> [String: String] {
        guard samples.count > 0 else {
            return [String:String]()
        }
        let sorted = samples.sorted { $0.time > $1.time }
        let olderThan = now - duration
        let idx = sorted.firstIndex(where:{ $0.time < olderThan }) ?? sorted.count

        guard idx > 0 else {
            return [String:String]()
        }
        let base = idx < sorted.count ? Array(sorted.prefix(upTo: idx)) : sorted
        let period = String(format: "%.2f", seconds(duration))
        let fullname = "\(name).\(period)"
        let byVal = base.sorted { $0.value < $1.value }
        let median = byVal[byVal.count/2].value
        let total = byVal.reduce(0) { $0 + $1.value }
        let mean = Double(total) / Double(byVal.count)
        let peak = byVal[byVal.count-1].value
        let low = byVal[0].value
        let perPeriod = Double(total) / fseconds(duration)
        let report = String(format: """
        { \"name\": \"\(name)\", \"period\": \(period), \"type\": \"int\", \"median\": %d, \"mean\": %.5f, \"peak\": %d, \"low\": %d, \"total\": %d,
          \"averagePerSecond\": %.5f, \"count\": %d }
        """, median, mean, peak, low, total, perPeriod, byVal.count)
        return [fullname:report]
    }

    var currentSampleIndex = 0
    private var samples: [Samples]

    var inflightTimers: [String: TimePoint]
    
    let clock: Clock
    //var periods: [(TimePoint, TimePoint)]
    let period: TimePoint
    var lastComputed: TimePoint
    var results: StatsResult?//(TimePoint, [String: String])?
    let idAsset: String?
    let queue: DispatchQueue
    let epoch: TimePoint
}

fileprivate struct Sample<T> {
    init( _ time: TimePoint, _ value: T) {
        self.time = time
        self.value = value
    }
    let time: TimePoint
    let value: T
}