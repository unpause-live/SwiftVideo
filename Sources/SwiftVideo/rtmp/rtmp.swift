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

import NIO
import NIOExtras
import Foundation
import Dispatch
import BrightFutures

public enum NoError : Error {}

public class Rtmp {
    public init(_ clock: Clock, 
        bufferSize: TimePoint = TimePoint(500, 1000), 
        onEnded: @escaping LiveOnEnded, 
        onConnection: @escaping LiveOnConnection) {

        self.clock = clock
        self.handshaking = [:]
        self.fnConnection = onConnection
        self.fnEnded = onEnded
        self.assets = [:]
        self.bufferSize = bufferSize
        self.publishers = [:]
        self.inflightConnections = Set<String>()
        self.inflightReconnects = Set<String>()
        self.queue = DispatchQueue(label: "rtmp")
    }

    public func connect(url: URL, 
                        publishToPeer: Bool, 
                        group: EventLoopGroup, 
                        workspaceId: String,
                        assetId: String? = nil,
                        uuid: String? = nil,
                        attempt: Int = 0) -> Bool {
        guard let host = url.host else {
            return false
        }
        let components = url.pathComponents
        let app = components[safe: 1] ?? ""
        let query = url.query?.split(separator: "/")
        let playPath = { () -> String in
            let base = components[safe: 2] ?? (query?[safe: 1].map { String($0) } ?? "")
            let qs = query <??> { if $0.count > 0 { return "?" + $0[0] } else { return "" } } <|> ""
            return base + qs
        }()

        let port = url.port ?? 1935

        let fnConnected = { [weak self] (conn: Connection) -> () in
            self?.queue.async { 
                guard let strongSelf = self else {
                    return
                }
                let query = (query?[safe: 0].map { String($0) } ?? "")
                let tcUrl = String(url.scheme ?? "rtmp") + "://" + host + ":" + String(port) + "/" + app + (query.count > 0 ? ("?" + query) : "")
                let ctx = rtmp.Context(assetId: assetId ?? UUID().uuidString,
                                       workspaceId: workspaceId,
                                       uuid: uuid,
                                       app: app,
                                       tcUrl: tcUrl,
                                       playPath: playPath,
                                       dialedOut: true,
                                       publishToPeer: publishToPeer,
                                       url: url.absoluteString)
                
                let handshake = rtmp.Handshake(ctx) {
                    [weak self] in
                    guard let strongSelf = self else {
                        return .gone
                    }
                    return strongSelf.handleCompletion($0, conn: conn)
                }
                strongSelf.handshaking[conn.ident] = conn >>> mix() >>> handshake >>> filter() >>> conn
                handshake.start()
            }
            
        }
        let fnEnded = { [weak self] (conn: Connection) -> () in
            let ident = conn.ident
            guard let strongSelf = self, strongSelf.inflightConnections.contains(ident) else {
                return
            }
            
            strongSelf.clock.schedule(TimePoint(1000, 1000) + strongSelf.clock.current()) { _ in
                self?.queue.async { 
                    guard let strongSelf = self else {
                        return
                    }
                    let shouldReconnect = (strongSelf.publishers[ident]?.value != nil || strongSelf.handshaking[ident] != nil) && attempt < 30
                    if shouldReconnect && !strongSelf.inflightReconnects.contains(ident) {
                        strongSelf.inflightReconnects.insert(ident)
                        strongSelf.clock.schedule(TimePoint(900000,100000) + strongSelf.clock.current()) { [weak self] _ in
                            self?.inflightReconnects.remove(ident)
                            guard let strongSelf = self,
                                (strongSelf.publishers[ident]?.value != nil || strongSelf.handshaking[ident] != nil) else {
                                return
                            }
                            strongSelf.handshaking.removeValue(forKey: ident)
                            strongSelf.publishers.removeValue(forKey: ident)
                            _ = strongSelf.connect(url: url, 
                                publishToPeer: publishToPeer, 
                                group: group, 
                                workspaceId: workspaceId, 
                                assetId: assetId, 
                                uuid: uuid,
                                attempt: attempt + 1)

                            if let assetId = strongSelf.assets[ident] {
                                strongSelf.fnEnded(assetId)
                                strongSelf.assets.removeValue(forKey: ident)
                            }
                        }
                    } else {
                        if let assetId = strongSelf.assets[ident] {
                            strongSelf.fnEnded(assetId)
                            strongSelf.assets.removeValue(forKey: ident)
                        }
                        strongSelf.handshaking.removeValue(forKey: ident)
                        strongSelf.publishers.removeValue(forKey: ident)
                    }
                    strongSelf.inflightConnections.remove(ident)
                }
            }
        }
        do {
            let connIdent = UUID().uuidString
            let scheme = url.scheme ?? "rtmp"
            if scheme == "rtmp" {
                _ = try tcpClient(group: group,
                              host: host,
                              port: port,
                              clock: clock,
                              uuid: connIdent,
                              connected: fnConnected,
                              ended: fnEnded).wait()
            } else {
                _ = try tlsClient(group: group,
                              host: host,
                              port: port,
                              clock: clock,
                              uuid: connIdent,
                              connected: fnConnected,
                              ended: fnEnded).wait()
            }
            self.inflightConnections.insert(connIdent)
        } catch {
            return false
        }
        return true
    }

    public func serve(host: String, port: Int, quiesce: ServerQuiescingHelper, group: EventLoopGroup? = nil) -> Bool {
        guard self.server == nil else {
            return false
        }
        let fnConnected = { [weak self] (conn: Connection) -> () in
            guard let strongSelf = self else {
                return
            }
            
            let handshake = rtmp.Handshake(rtmp.Context()) {
                [weak self] in
                guard let strongSelf = self else {
                    return .gone
                }
                return strongSelf.handleCompletion($0, conn: conn)
            }
            strongSelf.queue.async { 
                strongSelf.handshaking[conn.ident] = conn >>> mix() >>> handshake >>> filter() >>> conn
            }
        }
        let fnEnded = { [weak self] (conn: Connection) -> () in
            self?.queue.async { 
                guard let strongSelf = self else {
                    return
                }
                strongSelf.handshaking.removeValue(forKey: conn.ident)
                if let assetId = strongSelf.assets[conn.ident] {
                    strongSelf.fnEnded(assetId)
                    strongSelf.assets.removeValue(forKey: conn.ident)
                }
            }
        }
        let group = group ?? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.server = tcpServe(group: group,
                               host: host,
                               port: port,
                               clock: self.clock,
                               quiesce: quiesce,
                               connected: fnConnected,
                               ended: fnEnded)
        return true
    }
    
    public func wait() throws -> Bool {
        guard let server = self.server else {
            return false
        }
        try server.wait().closeFuture.wait()
        return true
    }

    public  func shutdown() {
        self.server = nil
    }

    private func handleCompletion(_ ctx: rtmp.Context, conn: Connection) -> EventBox<Event> {
        self.queue.async { [weak self] in
            self?.handshaking.removeValue(forKey: conn.ident)
        }

        if !ctx.dialedOut {
            let (success, ctx) = rtmp.buildStatus("status",
                                                  ctx.publishToPeer ? "NetStream.Play.Start" : "NetStream.Publish.Start",
                                                  "Begin",
                                                  ctx)
            let (fail, _) = rtmp.buildStatus("error",
                                             ctx.publishToPeer ? "NetStream.Play.Fail" : "NetStream.Publish.Fail",
                                             "No access",
                                             ctx)
            let publisher = ctx.publishToPeer ? RtmpPublisher(clock, conn: conn, ctx: ctx, bufferSize: self.bufferSize, uuid: ctx.uuid) : nil
            let subscriber = !ctx.publishToPeer ? RtmpSubscriber(clock, conn: conn, ctx: ctx) : nil

            _ = fnConnection(publisher, subscriber).andThen { [weak conn, weak self] result in
                self?.queue.async { 
                    guard let strongSelf = self, let conn = conn else {
                        return
                    }
                    if let val = result.value, val == true {
                        // emit success
                        if let val = success.value() as? NetworkEvent {
                            _ = conn <<| val
                        }
                        guard let assetId = (publisher?.uuid() ?? subscriber?.assetId()) else {
                            return
                        }
                        strongSelf.assets[conn.ident] = assetId
                    } else {
                        // disconnect
                        guard let assetId = (publisher?.uuid() ?? subscriber?.assetId()) else {
                            return
                        }
                        if let val = fail.value() as? NetworkEvent {
                            _ = conn <<| val
                        }
                        conn.close()
                        strongSelf.fnEnded(assetId)
                    }
                }
            }
        } else {
            let publisher = ctx.publishToPeer ? RtmpPublisher(clock, conn: conn, ctx: ctx, bufferSize: self.bufferSize, uuid: ctx.uuid) : nil
            let subscriber = !ctx.publishToPeer ? RtmpSubscriber(clock, conn: conn, ctx: ctx) : nil
            
            if let pub = publisher {
                let wkPublisher = Weak(value:pub)
                self.publishers[conn.ident] = wkPublisher
            }

            _ = fnConnection(publisher, subscriber).andThen { [weak self] result in
                self?.queue.async {
                    guard let assetId = (publisher?.uuid() ?? subscriber?.assetId()) else {
                        return
                    }
                    guard let strongSelf = self, let val = result.value, val == true else {
                        // disconnect
                        conn.close()
                        self?.fnEnded(assetId)
                        return
                    }
                    strongSelf.assets[conn.ident] = assetId
                }
            }
        }
        return .nothing(nil)
    }
    private let queue: DispatchQueue
    private let bufferSize: TimePoint
    private var channel: Channel?
    private let fnConnection: (LivePublisher?, LiveSubscriber?) -> Future<Bool, RpcError>
    private let fnEnded: (String) -> ()
    private let clock: Clock
    private var server: EventLoopFuture<Channel>?
    private var handshaking: [String:Tx<NetworkEvent,NetworkEvent>]
    private var assets: [String:String]
    private var publishers: [String: Weak<RtmpPublisher>]
    private var inflightConnections: Set<String>
    private var inflightReconnects: Set<String>
}

public class RtmpPublisher : Terminal<CodedMediaSample>, LivePublisher {
    fileprivate init(_ clock: Clock, conn: Connection, ctx: rtmp.Context, bufferSize: TimePoint, uuid: String?) {
        self.conn = conn
        self.tx = nil
        self.ctx = ctx
        let ident = uuid ?? UUID().uuidString
        self.ident = ident
        self.sentProps = false
        self.props = [BasicMediaDescription]()
        self.queue = DispatchQueue(label: "rtmp.publish.\(ident)")
        self.recv = nil
        super.init()
        super.set { [weak self] (sample: CodedMediaSample) -> EventBox<ResultEvent> in
            guard let strongSelf = self else {
                return .gone
            }
            if strongSelf.epoch == nil {
                strongSelf.epoch = clock.current() - sample.dts()
            }
            guard let epoch = strongSelf.epoch else {
                return .gone
            }
            if strongSelf.sentProps {
                let scheduleTime = epoch + bufferSize + sample.dts()
                clock.schedule(scheduleTime) { [weak self] _ in
                    self?.queue.async { [weak self] in 
                        guard let strongSelf = self, let tx = strongSelf.tx else {
                            return
                        }
                        self?.result = .just(sample) >>- (tx >>> Tx { .nothing($0.info()) })
                    }
                }
                let result = strongSelf.result
                strongSelf.result = nil
                return result ?? .nothing(nil)
            } else {
                let has = strongSelf.props.contains {
                    switch $0 {
                        case .video:
                            return sample.mediaType() == .video
                        case .audio:
                            return sample.mediaType() == .audio
                    }
                }
                if !has {
                    do {
                        try strongSelf.props.append(basicMediaDescription(sample))
                    } catch(let error) {
                        return .error(EventError("rtmp.mediaDescription", -1, "\(error)", assetId: sample.assetId()))
                    }
                }
                if strongSelf.props.count > 1 {
                    return strongSelf.sendMetadata()
                }
                return .nothing(sample.info())
            }
        }
        let serialize = rtmp.Serialize(ctx)
        self.tx = serialize >>> Tx { 
            $0.info()?.addSample("net.rtmp.write", $0.data().readableBytes)
            return .just($0)
        } >>> conn
        self.recv = conn >>> Tx<NetworkEvent, ResultEvent> {
            return .nothing($0.info())
        }
        clock.schedule(clock.current() + TimePoint(200,1000)) { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            _ = strongSelf.sendMetadata()
        }
    }
    deinit {
        sendUnpublish()
        self.conn.close()
    }
    public func assetId() -> String {
        return ctx.assetId
    }
    
    public func uri() -> String? {
        return ctx.url
    }

    public func app() -> String? {
        return ctx.app
    }

    public func uuid() -> String {
        return ident
    }
    public func liveType() -> MediaSourceType {
        return .rtmp
    }
    public func acceptedFormats() -> [MediaFormat] {
        return [.avc, .aac]
    }
    public func dialedOut() -> Bool {
        return ctx.dialedOut
    }
    public func workspaceId() -> String {
        return ctx.workspaceId ?? ctx.app ?? ""
    }

    public func workspaceToken() -> String? {
        return playPath()
    }

    public func playPath() -> String? {
        return ctx.playPath
    }
    
    public func tcUrl() -> String? {
        return ctx.tcUrl
    }
    
    public func encoder() -> String? {
        return ctx.encoder
    }

    private func sendUnpublish() {
        guard let tx = self.recv else {
            return
        }
        let result = rtmp.states.unpublish(ctx)
        ctx = result.1
        _ = result.0 >>- tx
    }
    private func sendMetadata() -> EventBox<ResultEvent> {
        guard let tx = self.recv, sentProps == false else {
            return .nothing(nil)
        }
        sentProps = true
        do {
            let data = try rtmp.serialize.createMetadata(props, ctx: ctx)
            defer {
                ctx = data.1
            }
            if let bytes = data.0 {
                return .just(NetworkEvent(time: nil,
                               assetId: ctx.assetId,
                               workspaceId: ctx.app ?? "",
                               workspaceToken: ctx.playPath,
                               bytes: bytes)) >>- tx
            } else {
                return .nothing(nil)
            }
        } catch(let error) {
            return .error(EventError("rtmp.mediaDescription", -2, "\(error)", assetId: ctx.assetId))
        }
    }
    private let queue: DispatchQueue
    private var result: EventBox<ResultEvent>? = nil
    private var epoch: TimePoint? = nil
    private var props: [BasicMediaDescription]
    private var sentProps: Bool
    private var ctx: rtmp.Context
    private let conn: Connection
    private let ident: String
    private var tx: Tx<CodedMediaSample, NetworkEvent>?
    private var recv: Terminal<NetworkEvent>?
}

public class RtmpSubscriber : Source<CodedMediaSample>, LiveSubscriber {
    fileprivate init(_ clock: Clock, conn: Connection, ctx: rtmp.Context) {
        self.conn = conn
        self.tx = nil
        self.ctx = ctx
        self.statsReport = StatsReport(assetId: ctx.assetId, clock: clock)
        super.init()
        self.tx = conn >>> rtmp.Deserialize(clock, ctx) >>> Tx<[CodedMediaSample], Event> {
            [weak self] in
            guard let strongSelf = self else {
                return .gone
            }
            let result = $0.reduce(EventBox<Event>.nothing(nil)) { (acc, sample) in
                strongSelf.statsReport.addSample("rtmp.\(sample.mediaFormat()).recv", sample.data().count)
                let sample = CodedMediaSample(sample, eventInfo: strongSelf.statsReport)
               
                return strongSelf.emit(sample).flatMap { .just($0 as Event) }
            }
            return result
        }
    }
    public func assetId() -> String {
        return ctx.assetId
    }

    public func uuid() -> String {
        return ctx.assetId
    }
    public func liveType() -> MediaSourceType {
        return .rtmp
    }
    public func workspaceId() -> String {
        return ctx.app ?? ""
    }

    public func workspaceToken() -> String? {
        return playPath()
    }
    public func suppliedFormats() -> [MediaFormat] {
        return [.avc, .aac]
    }
    public func app() -> String? {
        return ctx.app
    }
    
    public func playPath() -> String? {
        return ctx.playPath
    }
    
    public func tcUrl() -> String? {
        return ctx.tcUrl
    }
    
    public func dialedOut() -> Bool {
        return ctx.dialedOut
    }
    
    public func encoder() -> String? {
        return ctx.encoder
    }
    private let statsReport: StatsReport
    private let ctx: rtmp.Context
    private let conn: Connection
    private var tx: Tx<NetworkEvent, Event>?
}

enum rtmp {
    
    typealias StateFunction = (ByteBuffer, Context) -> (EventBox<Event>, ByteBuffer?, Context, Bool)
    
    static func buildStatus(_ level: String, _ code: String, _ description: String, _ ctx: rtmp.Context) -> (EventBox<Event>, rtmp.Context) {
        let chunk = rtmp.Chunk(msgStreamId: ctx.msgStreamId,
                               msgLength: 0,
                               msgType: 0x14,
                               chunkStreamId: 3,
                               timestamp: 0,
                               timestampDelta: 0,
                               data: nil)
        return states.onStatus(level, code: code, desc: description, ctx: ctx, chunk: chunk)
    }
    
    class Serialize : Tx<CodedMediaSample, NetworkEvent> {
        init(_ ctx: Context) {
            self.ctx = ctx
            self.prevConfig = [MediaType: ByteBuffer]()
            self.sentFirstKeyframe = false
            super.init()
            super.set { [weak self] sample in
                guard let strongSelf = self else {
                    return .gone
                }
                let mediaType = sample.mediaType()
                let prevConfig = strongSelf.prevConfig[mediaType]
                let curConfig = sample.sideData()["config"].map { buffer.fromData($0) }
                sample.info()?.addSample("net.rtmp.\(sample.mediaFormat()).dts", sample.dts())
                sample.info()?.addSample("net.rtmp.\(sample.mediaFormat()).pts", sample.pts())
                if let curConfig = curConfig, let prevConfig = prevConfig, prevConfig == curConfig {
                    // config is unchanged
                    let result = serialize.serializeMedia(sample, ctx: strongSelf.ctx)
                    strongSelf.ctx = result.1
                    return makeNetworkResult(sample, result.0)
                } else if let curConfig = curConfig {
                    // have a config but haven't sent it, or config changed
                    if mediaType == .audio || (mediaType == .video && (strongSelf.sentFirstKeyframe || isKeyframe(sample))) {
                        let header = serialize.serializeMedia(sample, ctx: strongSelf.ctx, sendConfig: true)
                        let result = serialize.serializeMedia(sample, ctx: header.1)
                        if mediaType == .video && !strongSelf.sentFirstKeyframe {
                            print("keyframe \(sample.dts().toString())")
                            strongSelf.sentFirstKeyframe = true
                        }
                        strongSelf.ctx = result.1
                        strongSelf.prevConfig = strongSelf.prevConfig.merging([mediaType: curConfig]) { $1 }
                        return makeNetworkResult(sample, buffer.concat(header.0,result.0))
                    } else {
                        return .nothing(sample.info())
                    }
                } else {
                    // no config
                     let result = serialize.serializeMedia(sample, ctx: strongSelf.ctx)
                    strongSelf.ctx = result.1
                    return makeNetworkResult(sample, result.0)
                }
            }
        }
        private var ctx: Context
        private var prevConfig: [MediaType: ByteBuffer]
        private var sentFirstKeyframe: Bool
    }
    
    fileprivate static func makeNetworkResult(_ sample: CodedMediaSample, _ buffer: ByteBuffer?) -> EventBox<NetworkEvent> {
        return buffer <??>
            { .just(NetworkEvent(time: sample.time(),
                                 assetId: sample.assetId(),
                                 workspaceId: sample.workspaceId(),
                                 workspaceToken: sample.workspaceToken(),
                                 bytes: $0,
                                 info: sample.info())) } <|>
            .nothing(sample.info())
    }
    
    class Deserialize : Tx<NetworkEvent, [CodedMediaSample]> {
        init(_ clock: Clock, _ ctx: Context) {
            self.ctx = ctx
            self.clock = clock
            self.queue = DispatchQueue(label: "rtmp.deserialize.\(clock.current().value)")
            super.init()
            super.set { [weak self] sample in
                guard let strongSelf = self else {
                    return .gone
                }
                var samples = [CodedMediaSample]()
                strongSelf.queue.sync {
                    guard var data = buffer.concat(strongSelf.accumulator, sample.data()) else {
                        return
                    }
                    process: repeat {
                        let readable = data.readableBytes
                        let (buf, chk, ctx) = deserialize.parseChunk(data, ctx: strongSelf.ctx)
                        strongSelf.ctx = ctx
                        if let chunk = chk {
                            let result = states.handleChunk(chunk, ctx: strongSelf.ctx, clock: strongSelf.clock)
                            strongSelf.ctx = result.1
                            if let mediaSample = result.0.value() as? CodedMediaSample {
                                samples.append(mediaSample)
                            }
                        }
                        if let buf = buf {
                            data = buf
                            strongSelf.accumulator = data
                            if buf.readableBytes == readable || buf.readableBytes == 0 {
                                break process
                            }
                        } else {
                            break process
                        }
                    } while true
                    strongSelf.accumulator = buffer.rebase(strongSelf.accumulator)
                }
                return .just(samples)
            }
        }
        private let queue: DispatchQueue
        private let clock: Clock
        private var accumulator: ByteBuffer?
        private var ctx: Context
    }
    
    class Handshake : Source<Event> {
        public init(_ ctx: Context, completion: @escaping (Context) -> EventBox<Event>) {
            self.stages = ctx.dialedOut ? [states.s0s1, states.s2, states.establish] : [states.c0c1, states.c2, states.establish]
            self.stage = 0
            self.ctx = ctx
            self.onComplete = completion
            self.accumulator = nil
            super.init()
            super.set {
                [weak self] evt in
                guard let strongSelf = self else {
                    return .gone
                }
                if evt.assetId() != strongSelf.ctx.assetId {

                    guard let data = buffer.concat(strongSelf.accumulator, (evt as? NetworkEvent)?.data()) else {
                        return .nothing(evt.info())
                    }
                    return strongSelf.impl(data)
                } else {
                    return (evt as? NetworkEvent) <??> { .just($0) } <|> .nothing(evt.info())
                }
            }
        }
        public func start() {
            DispatchQueue.global().asyncAfter(wallDeadline: DispatchWallTime.now() + DispatchTimeInterval.milliseconds(250)) {
                let c0c1 = states.writeC0c1(self.ctx)
                self.ctx = c0c1.2
                _ = c0c1.0 >>- self.emit
            }
        }
        private func impl(_ buf: ByteBuffer) -> EventBox<Event> {
            var buf = buf
            var work: ByteBuffer? = nil
            process: repeat {
                let readable = buf.readableBytes
                guard let result = self.stages[safe: self.stage]?(buf, self.ctx) else {
                    return .gone
                }
                switch(result.0) {
                case .error(let error):
                    return .error(error)
                case .gone:
                    return .gone
                default: ()
                }
                if result.3 == true {
                    self.stage = self.stage + 1
                }
                if result.2.started == true {
                    return self.onComplete(result.2)
                }
                self.accumulator = result.1
                
                self.ctx = result.2
                if let val = result.0.value() as? NetworkEvent {
                    work = buffer.concat(work, val.data())
                }
                guard let pBuf = result.1 else {
                    break process
                }
                if pBuf.readableBytes == readable || pBuf.readableBytes == 0 {
                    break process
                }
                buf = pBuf
            } while true
            
            //self.accumulator?.discardReadBytes()
            self.accumulator = buffer.rebase(self.accumulator)

            return work <??> { .just(NetworkEvent(time: nil,
                                                  assetId: self.ctx.assetId,
                                                  workspaceId: self.ctx.app ?? "",
                                                  workspaceToken: self.ctx.playPath,
                                                  bytes: $0)) } <|> .nothing(nil)
        }
        private let onComplete: (Context) -> EventBox<Event>
        private let stages: [StateFunction]
        private var stage: Int
        private var accumulator: ByteBuffer?
        private var ctx: Context
    }

    struct Context {
        let inChunkSize : Int
        let outChunkSize : Int
        let inChunks : [Int:Chunk]
        let outChunks: [Int:Chunk]
        let lastChunk0: [Int:Int]
        let assetId: String
        let workspaceId: String?
        let app: String?
        let uuid: String?
        let tcUrl: String?
        let playPath: String?
        let msgStreamId: Int
        let started: Bool
        let dialedOut: Bool
        let publishToPeer: Bool
        let sideData: [String: Data]
        let encoder: String?
        let commandNumber: Int
        let commandResponder: [Int: ([amf.Atom], Chunk, Context) -> (EventBox<Event>, Context)]?
        let url: String?

        init(assetId: String = UUID().uuidString,
             workspaceId: String? = nil,
             uuid: String? = nil,
             inChunkSize: Int = 128,
             outChunkSize: Int = 128,
             inChunks: [Int:Chunk] = [:],
             outChunks: [Int:Chunk] = [:],
             lastChunk0: [Int:Int] = [:],
             app: String? = nil,
             tcUrl: String? = nil,
             playPath: String? = UUID().uuidString,
             msgStreamId: Int = 0,
             started: Bool = false,
             dialedOut: Bool = false,
             publishToPeer: Bool = false,
             sideData: [String: Data] = [String:Data](),
             encoder: String? = nil,
             commandNumber: Int = 1,
             commandResponder: [Int: ([amf.Atom], Chunk, Context) -> (EventBox<Event>, Context)]? =
                                [Int: ([amf.Atom], Chunk, Context) -> (EventBox<Event>, Context)](),
             url: String? = nil) {
            self.assetId = assetId
            self.uuid = uuid
            self.inChunkSize = inChunkSize
            self.outChunkSize = outChunkSize
            self.inChunks = inChunks
            self.outChunks = outChunks
            self.lastChunk0 = lastChunk0
            self.started = started
            self.app = app
            self.tcUrl = tcUrl
            self.playPath = playPath
            self.msgStreamId = msgStreamId
            self.dialedOut = dialedOut
            self.publishToPeer = publishToPeer
            self.sideData = sideData
            self.encoder = encoder
            self.commandNumber = commandNumber
            self.commandResponder = commandResponder
            self.workspaceId = workspaceId
            self.url = url
        }
        func changing (assetId: String? = nil,
                       workspaceId: String? = nil,
                       uuid: String? = nil,
                       inChunkSize: Int? = nil,
                       outChunkSize: Int? = nil,
                       inChunks: [Int:Chunk]? = nil,
                       outChunks: [Int:Chunk]? = nil,
                       lastChunk0: [Int:Int]? = nil,
                       app: String? = nil,
                       tcUrl: String? = nil,
                       playPath: String? = nil,
                       msgStreamId: Int? = nil,
                       started: Bool? = nil,
                       dialedOut: Bool? = nil,
                       publishToPeer: Bool? = nil,
                       sideData: [String:Data]? = nil,
                       encoder: String? = nil,
                       commandNumber: Int? = nil,
                       commandResponder: [Int: ([amf.Atom], Chunk, Context) -> (EventBox<Event>, Context)]? = nil,
                       url: String? = nil) -> Context {
            return Context(assetId: assetId ?? self.assetId,
                           workspaceId: workspaceId ?? self.workspaceId,
                           uuid: uuid ?? self.uuid,
                           inChunkSize: inChunkSize ?? self.inChunkSize,
                           outChunkSize: outChunkSize ?? self.outChunkSize,
                           inChunks: inChunks ?? self.inChunks,
                           outChunks: outChunks ?? self.outChunks,
                           lastChunk0: lastChunk0 ?? self.lastChunk0,
                           app: app ?? self.app,
                           tcUrl: tcUrl ?? self.tcUrl,
                           playPath: playPath ?? self.playPath,
                           msgStreamId: msgStreamId ?? self.msgStreamId,
                           started: started ?? self.started,
                           dialedOut: dialedOut ?? self.dialedOut,
                           publishToPeer: publishToPeer ?? self.publishToPeer,
                           sideData: sideData ?? self.sideData,
                           encoder: encoder ?? self.encoder,
                           commandNumber: commandNumber ?? self.commandNumber,
                           commandResponder: commandResponder ?? self.commandResponder,
                           url: url ?? self.url)
        }
    }
    
    struct Chunk {
        let msgStreamId : Int
        let msgLength : Int
        let msgType : Int
        let chunkStreamId : Int
        let timestamp : Int
        let timestampDelta : Int
        let extended : Bool
        let data : ByteBuffer?
        init(msgStreamId: Int,
             msgLength: Int,
             msgType: Int,
             chunkStreamId: Int,
             timestamp: Int,
             timestampDelta: Int,
             extended: Bool = false,
             data: ByteBuffer?) {
            self.msgStreamId = msgStreamId
            self.msgLength = msgLength
            self.msgType = msgType
            self.chunkStreamId = chunkStreamId
            self.timestamp = timestamp
            self.timestampDelta = timestampDelta
            self.extended = extended
            self.data = data
        }
        func changing (msgStreamId: Int? = nil,
                       msgLength: Int? = nil,
                       msgType: Int? = nil,
                       chunkStreamId: Int? = nil,
                       timestamp: Int? = nil,
                       timestampDelta: Int? = nil,
                       extended: Bool? = nil,
                       data: ByteBuffer?) -> Chunk {
            return Chunk(msgStreamId: msgStreamId ?? self.msgStreamId,
                         msgLength: msgLength ?? self.msgLength,
                         msgType: msgType ?? self.msgType,
                         chunkStreamId: chunkStreamId ?? self.chunkStreamId,
                         timestamp: timestamp ?? self.timestamp,
                         timestampDelta: timestampDelta ?? self.timestampDelta,
                         extended: extended ?? self.extended,
                         data: data)
        }
    }
}
