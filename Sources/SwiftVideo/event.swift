
extension EventError {
    public init(_ src: String, _ code: Int, _ desc: String? = nil, _ time: TimePoint? = nil, assetId: String? = nil) {
        self.source = src
        self.code = Int32(code)
        if let assetId = assetId {
            self.assetID = assetId
        }
        if let desc = desc {
            self.desc = desc
        }
        if  let time = time {
            self.time = time
        }
    }
}

public typealias EventInfo = StatsReport

public protocol Event {
    func type() -> String
    func time() -> TimePoint
    func assetId() -> String
    func workspaceId() -> String
    func workspaceToken() -> String?
    func info() -> EventInfo?
}

extension Array : Event where Element: Event {
    public func type() -> String { return "list" }
    public func time() -> TimePoint { return self.last <??> { $0.time() } <|> TimePoint(0) }
    public func assetId() -> String {  return self.last <??> { $0.assetId() } <|> "none" }
    public func workspaceId() -> String { return self.last <??> { $0.workspaceId() } <|> "none" }
    public func workspaceToken() -> String? {  return self.last?.workspaceToken() }

    public func info() -> EventInfo? { return self.reduce(nil) {
        guard let acc = $0 else {
            return $1.info()
        }
        guard let val = $1.info() else {
            return acc
        }
        return acc.merging(val)
        }
    }
}

public enum EventBox<T> {
    case just(T)
    case error(EventError)
    case nothing(EventInfo?)
    case gone   // next item in chain is gone, stop calling
}

extension EventBox {
    public func flatMap<U>(_ fun: @escaping (T) -> EventBox<U>) -> EventBox<U> {
        switch(self) {
        case .just(let payload):
            return fun(payload)
        case .error(let error):
            return .error(error)
        case .nothing(let info):
            return .nothing(info)
        case .gone:
            return .gone
        }
    }
    
    public func map<U>(_ fun: @escaping (T) -> U) -> EventBox<U> {
        switch(self) {
        case .just(let payload):
            return .just(fun(payload))
        case .error(let error):
            return .error(error)
        case .nothing(let info):
            return .nothing(info)
        case .gone:
            return .gone
        }
    }
    
    public func apply<U>(_ fun: EventBox<(T) -> U>) -> EventBox<U> {
        switch(fun) {
        case .just(let fun):
            return map(fun)
        case .error(let error):
            return .error(error)
        case .nothing(let info):
            return .nothing(info)
        case .gone:
            return .gone
        }
    }
    
    public func value() -> T? {
        guard case let .just(val) = self else {
            return nil
        }
        return val
    }
    
    public func error() -> EventError? {
        guard case let .error(val) = self else {
            return nil
        }
        return val
    }
}

precedencegroup ApplyGroup { associativity: left higherThan: AssignmentPrecedence }
infix operator >>- : ApplyGroup
infix operator <*> : ApplyGroup

public func <*> <T, U> (_ lhs: EventBox<(T) -> U>, _ rhs: EventBox<T>) -> EventBox<U> {
    return rhs.apply(lhs)
}

public func >>- <T, U> (_ lhs: EventBox<T>, _ rhs: @escaping (T) -> EventBox<U>) -> EventBox<U> {
    return lhs.flatMap(rhs)
}

public final class ResultEvent : Event {
    public func type() -> String { return "result" }
    public func time() -> TimePoint { return timePoint }
    public func assetId() -> String { return idAsset }
    public func workspaceId() -> String { return idWorkspace }
    public func workspaceToken() -> String? { return tokenWorkspace }
    public func info() -> EventInfo? { return eventInfo }
    
    public init(time: TimePoint?, assetId: String?, workspaceId: String?, workspaceToken: String?) {
        self.timePoint = time ?? TimePoint(0, 1000)
        self.idAsset = assetId ?? ""
        self.idWorkspace = workspaceId ?? ""
        self.tokenWorkspace = workspaceToken
        self.eventInfo = nil
    }
    let timePoint : TimePoint
    let idAsset: String
    let idWorkspace: String
    let tokenWorkspace: String?
    let eventInfo : EventInfo?
}

