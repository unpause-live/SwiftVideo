
// Repeats a sample at a specified interval if a new one is not provided.
public class Repeater<T>: AsyncTx<T, T> {
    public init(_ clock: Clock, interval: TimePoint) {
        self.clock = clock
        self.lastEmit = clock.current()
        super.init()
        let interval = rescale(interval, clock.current().scale)
        super.set { [weak self] in
            guard let strongSelf = self else {
                return .gone
            }
            strongSelf.sample = $0
            let now = strongSelf.clock.current()
            strongSelf.lastEmit = now
            strongSelf.run(interval)
            return .just($0)
        }
    }
    deinit {
        print("repeater deinit")
    }
    private func run(_ interval: TimePoint) {
        let now = self.clock.current()
        self.clock.schedule(now + interval) { [weak self] at in
            guard let strongSelf = self, let sample = strongSelf.sample else {
                return
            }
            if (strongSelf.lastEmit + interval) <= at.timePoint {
                _ = strongSelf.emit(sample)
                strongSelf.lastEmit = at.timePoint
                strongSelf.run(interval)
            }
        }
    }
    private let clock: Clock
    private var sample: T?
    private var lastEmit: TimePoint
}