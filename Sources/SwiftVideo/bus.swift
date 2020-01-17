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

import Dispatch
import Foundation
import BrightFutures
import NIO
import Logging

public let kFlick: Int64 = 100000

public class Bus<EventType> {
    private var observers = [((EventType) -> EventBox<Event>, Int, String)]()
    private let clock: Clock
    private let queue: DispatchQueue
    private let runner: [DispatchQueue]
    private let listQueue: DispatchQueue
    private let ident: String
    private let logger: Logging.Logger
    private var events = [EventBox<EventType>]()
    private var granularity = TimePoint(0, kFlick)
    private var lastapply = TimePoint(0, kFlick)
    private var fnDigest: (([EventBox<Event>]) -> Void)?
    private var eventsIn = 0
    private var eventsOut = 0

    public init(ident: String? = nil,
                poolSize: Int = System.coreCount,
                logger: Logging.Logger = Logger(label: "SwiftVideo")) {
        self.clock = WallClock()
        let uuid = ident ?? UUID().uuidString
        self.ident = uuid
        self.queue = DispatchQueue(label: "bus.dispatch.\(uuid)")
        self.logger = logger
        self.runner = (0..<poolSize).map {
            DispatchQueue(label: "bus.dispatch.\(uuid).\($0)")
        }
        self.listQueue = DispatchQueue(label: "bus.events.\(uuid)")
    }

    public init(_ clock: Clock,
                ident: String? = nil,
                poolSize: Int = System.coreCount,
                logger: Logging.Logger = Logger(label: "SwiftVideo")) {
        self.clock = clock
        let uuid = ident ?? UUID().uuidString
        self.ident = uuid
        self.queue = DispatchQueue(label: "bus.dispatch.\(uuid)")
        self.logger = logger
        self.runner = (0..<poolSize).map {
            DispatchQueue(label: "bus.dispatch.\(uuid).\($0)")
        }
        self.listQueue = DispatchQueue(label: "bus.events.\(uuid)")
    }

    public func getClock() -> Clock { return clock }

    public func addObserver(_ obs: @escaping (EventType) -> EventBox<Event>) {
        let observer = (obs, Int.random(in: 0..<self.runner.count), UUID().uuidString)
        self.listQueue.sync(flags: .barrier) {
            self.observers.append(observer)
        }
    }

    // Appends event e to the received events queue and maybe notifies
    // observers.  If no granularity is set it will notify on each append
    // If a granularity is set it will only notify with that granularity
    public func append(_ evt: EventBox<EventType>) -> EventBox<ResultEvent> {
        let applyQueue : () -> Bool = {
            let time = self.clock.current()
            let delta = time - self.lastapply
            let res = delta >= self.granularity
            if res {
                self.lastapply = time
            }
            return res
        }
        self.listQueue.async(flags: .barrier) { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.events.append(evt)
            strongSelf.eventsIn += 1
            if applyQueue() {
                strongSelf.fireBusEvents()
            }
        }
        return evt >>- { [weak self] sample in
            if let event = sample as? Event {
                return .nothing(event.info())
            } else {
                self?.logger.error("Got something that wasn't castable to event, \(sample)")
                return .nothing(nil)
            }
        }
    }

    func fireBusEvents() {
        var evts = [EventBox<EventType>]()
        let count = self.events.count
        if count > 0 {
            evts = Array(self.events[0..<count])
            self.events.removeAll(keepingCapacity: true)
            self.queue.async { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.eventsOut += evts.count
                var observers: [((EventType) -> EventBox<Event>, Int, String)]?
                strongSelf.listQueue.sync(flags: .barrier) {
                    observers = strongSelf.observers
                }
                if let observers = observers {
                    let futureResults: [Future<(EventBox<Event>, String), Never>] = evts.flatMap { event in
                        return observers.map { observer in
                            let (fun, idx, ident) = observer
                            return Future<(EventBox<Event>, String), Never> { [weak self] complete in
                                guard let strongSelf = self, let runner = strongSelf.runner[safe:idx] else {
                                    complete(.success((.gone, ident)))
                                    return
                                }
                                runner.async {
                                    complete(.success( (event >>- fun, ident) ))
                                }
                            }
                        }
                    }
                    futureResults.sequence().onSuccess { [weak self] results in
                        self?.listQueue.async(flags: .barrier) { [weak self] in
                            guard let strongSelf = self else {
                                return
                            }
                            let toRemove = results.filter { if case .gone = $0.0 { return true } ; return false }
                            strongSelf.observers.removeAll { observer in toRemove.contains { observer.2 == $0.1 } }
                            strongSelf.fnDigest?(results.map { $0.0 })
                        }
                    }
                }
            }
        }
    }

    public func setDigestReceiver(_ fun: @escaping ([EventBox<Event>]) -> Void) {
        self.fnDigest = fun
    }

    public func setGranularity(_ val: TimePoint) {
        self.granularity = rescale(val, kFlick)
    }
}

public typealias HeterogeneousBus = Bus<Event>

public final class Digest: Event {
    public let events: [Event?]
    public let timePoint: TimePoint

    public required init() {
        self.events = [Event?]()
        self.timePoint = TimePoint(0)
    }

    public func type() -> String {
        return "digest"
    }

    public func assetId() -> String {
        return "bus"
    }

    public func workspaceId() -> String {
        return "bus"
    }

    public func workspaceToken() -> String? {
        return nil
    }

    public func time() -> TimePoint {
        return timePoint
    }

    public func info() -> EventInfo? {
        return self.events.reduce(nil) {
            guard let acc = $0 else {
                return $1?.info()
            }
            guard let info = $1?.info() else {
                return acc
            }
            return acc.merging(info)
        }
    }

    init(_ evt: [Event?], time: TimePoint) {
        self.events = evt
        self.timePoint = time
    }
}

// swiftlint:disable:next type_name
open class Tx <T, U> {
    fileprivate var fun: ((T) -> EventBox<U>)?
    public init(_ fun: @escaping (T) -> EventBox<U>) { set(fun) }
    public init() {}
    public func set(_ fun: @escaping (T) -> EventBox<U>) {
        self.fun = fun
    }
}

extension EventBox {
    public func flatMap <U> ( _ fun: Tx<T, U> ) -> EventBox<U> {
        switch self {
        case .just(let payload):
            return fun.fun <??> { $0(payload) } <|> .nothing(((payload as? Event) <??> { $0.info() } <|> nil))
        case .error(let error):
            return .error(error)
        case .nothing(let info):
            return .nothing(info)
        case .gone:
            return .gone
        }
    }
}

open class AsyncTx <T, U> : Tx<T, U> {
    public override init() {
        super.init { ($0 as? U) <??> { .just($0) } <|> .error(EventError("asynctx", -1, "incorrect sample type")) }
    }
    public func setEmitFn(_ fun: @escaping (U) -> EventBox<Event>) { fnEmit = fun }
    public func emit(_ val: U) -> EventBox<Event> {
        guard let emit = fnEmit else {
            return .gone
        }
        let result = emit(val)
        if let fnDigest = self.fnDigest {
            fnDigest([result])
        }
        return result
    }
    public func setDigestReceiver(_ fun: @escaping ([EventBox<Event>]) -> Void) {
        self.fnDigest = fun
    }
    private var fnEmit: ((U) -> EventBox<Event>)?
    private var fnDigest: (([EventBox<Event>]) -> Void)?
}

open class Source<U>: AsyncTx<U, U> {}

public typealias Terminal<T> = Tx<T, ResultEvent>

public func filter <U> () -> Tx<Event, U> where U: Event {
    return Tx {
        if let val = $0 as? U {
            return .just(val)
        } else {
            return .nothing($0.info())
        }
    }
}

public func assetFilter <U> (_ assetId: String) -> Tx<U, U> where U: Event {
    return Tx {
        if $0.assetId() == assetId {
            return .just($0)
        } else {
            return .nothing($0.info())
        }
    }
}

public func mix <U> () -> Tx<U, Event> where U: Event {
    return Tx { .just($0) }
}

precedencegroup WrapGroup { associativity: left higherThan: AssignmentPrecedence }
precedencegroup PipeGroup { associativity: right higherThan: WrapGroup }

infix operator >>> : PipeGroup
infix operator |>> : PipeGroup
infix operator <<| : WrapGroup

public func >>- <T, U> (box: EventBox<T>, fun: Tx<T, U>) -> EventBox<U> {
    return box.flatMap(fun)
}

public func >>- <T> (box: EventBox<T>, bus: Bus<T>) -> EventBox<ResultEvent> {
    return bus.append(box)
}

public func >>> <T, U, V>(left: AsyncTx<T, U>, right: Tx<U, V>) -> Tx<T, V> where V: Event {
    let txn = Tx { .just($0) >>- left >>- right }
    left.setEmitFn { [weak txn, weak right] in
        if let right = right, txn != nil {
            return .just($0) >>- right >>- { .just($0 as Event) }
        }
        return .gone
    }
    return txn
}
public func >>> <T, U>(left: AsyncTx<T, U>, right: Tx<U, Event>) -> Tx<T, Event> {
    let txn = Tx { .just($0) >>- left >>- right }

    left.setEmitFn { [weak txn, weak right] in
        if let right = right, txn != nil {
            return .just($0) >>- right >>- { .just($0) }
        }
        return .gone
    }
    return txn
}

public func |>> <T, U, V>(left: Tx<T, [U]>, right: Tx<U, V>) -> Tx<T, [V]> {
    return Tx { event in
        let lres = (.just(event) >>- left)
        let result = lres.value()?.compactMap { .just($0) >>- right }

        return result <??> { EventBox<[V]>.just($0.compactMap { $0.value() }) } <|> .nothing(nil)
    }
}
public func |>> <T, U>(left: Tx<T, [U]>, right: Bus<U>) -> Tx<T, ResultEvent> {
    return Tx {
        let result = (.just($0) >>- left).value()?.compactMap { right.append(.just($0)) }
                     .compactMap { $0.value() }
        return result?.last <??> { .just($0) } <|> .nothing(nil)
    }
}

public func >>> <T, U, V>(left: Tx<T, U>, right: Tx<U, V>) -> Tx<T, V> {
    return Tx { .just($0) >>- left >>- right }
}

public func >>> <T, V> (left: Tx<T, V>, right: Bus<V>) -> Tx<T, ResultEvent> {
    return Tx { right.append(.just($0) >>- left) }
}

public func >>> <T, U> (left: AsyncTx<T, U>, right: Bus<U>) -> Tx <T, ResultEvent> {
    let txn = Tx<T, ResultEvent> { right.append(.just($0) >>- left) }
    left.setEmitFn { [weak txn, weak right] in
        if let right = right, txn != nil {
            return right.append(.just($0)) >>- { .just($0 as Event) }
        }
        return .gone
    }
    return txn
}

public func <<| <T, V>(left: Tx<T, V>, right: T) -> EventBox<V> {
    return .just(right) >>- left
}

public func <<| <T, V> (left: Bus<T>, right: Tx <T, V> ) -> Tx<T, V> where V: Event {
    left.addObserver { [weak right] (val) in
        guard let strongRight = right else {
            return .gone
        }
        return .just(val) >>- strongRight >>- { .just($0 as Event) }
    }
    return right
}
