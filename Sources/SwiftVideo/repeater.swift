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
        self.clock.schedule(now + interval) { [weak self] evt in
            guard let strongSelf = self, let sample = strongSelf.sample else {
                return
            }
            if (strongSelf.lastEmit + interval) <= evt.timePoint {
                _ = strongSelf.emit(sample)
                strongSelf.lastEmit = evt.timePoint
                strongSelf.run(interval)
            }
        }
    }
    private let clock: Clock
    private var sample: T?
    private var lastEmit: TimePoint
}
