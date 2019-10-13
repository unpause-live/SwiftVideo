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

public class Flavor {
    public init(_ clock: Clock, onEnded: @escaping LiveOnEnded, 
            onConnection: @escaping (String) -> (), 
            formatQuery: @escaping (String, String?) -> [MediaFormat]?,
            onStreamEstablished: @escaping LiveOnConnection) {
        self.clock = clock
        self.sessions = [String:FlavorSession]()
        self.fnConnection = onConnection
        self.fnStreamEstablished = onStreamEstablished
        self.fnEnded = onEnded
        self.fnFormatQuery = formatQuery
    }

    public func serve(host: String, port: Int, quiesce: ServerQuiescingHelper, group: EventLoopGroup? = nil) -> Bool {
        guard self.server == nil else {
            return false
        }
        let fnConnected = { [weak self] (conn: Connection) -> () in
            guard let strongSelf = self else {
                return
            }
            strongSelf.sessions[conn.ident] = FlavorSession(strongSelf.clock, 
                conn: conn, 
                dialedOut: false,
                formatQuery: strongSelf.fnFormatQuery,
                onEnded: strongSelf.fnEnded, 
                onStreamEstablished: strongSelf.fnStreamEstablished) { [weak self] in
                    if $0  {
                        self?.fnConnection(conn.ident)
                    }
            }
            
        }

        let fnEnded = { [weak self] (conn: Connection) -> () in
            guard let strongSelf = self else {
                return
            }
            strongSelf.sessions.removeValue(forKey: conn.ident)
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
    public func connect(url: URL, 
                        group: EventLoopGroup, 
                        workspaceId: String) -> String {
        guard let host = url.host else {
            return ""
        }
        let port = url.port ?? 3751
        let sessionId = UUID().uuidString
        
        let fnConnected = { [weak self] (conn: Connection) -> () in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.sessions[sessionId] = FlavorSession(strongSelf.clock, 
                conn: conn, 
                dialedOut: true,
                sessionId: sessionId,
                formatQuery: strongSelf.fnFormatQuery,
                onEnded: strongSelf.fnEnded, 
                onStreamEstablished: strongSelf.fnStreamEstablished) { [weak self] in
                    if $0  {
                        self?.fnConnection(sessionId)
                    } else {

                    }
            }
            
        }
        let fnEnded = { [weak self] (conn: Connection) -> () in
            guard let strongSelf = self else {
                return
            }
            strongSelf.sessions.removeValue(forKey: sessionId)
        }
        do {
            _ = try tcpClient(group: group,
                      host: host,
                      port: port,
                      clock: clock,
                      connected: fnConnected,
                      ended: fnEnded).wait()
        } catch {
            return ""
        }
        

        return sessionId
    }
    
    public func makePush(_ sessionId: String, token: String, onError: @escaping (String?) -> ()) -> Bool {
        guard let session = sessions[sessionId] else {
            return false
        }
        do {
            try session.sendPush(token) { [weak self] _, response, reason, atom in
                if response == 0 {
                    // make a publisher
                    if let session = self?.sessions[sessionId] {
                        let parts = token.split(separator: "/") // We know this has 2 parts because it will have been verified by sendPush
                        session.makePublisher(UUID().uuidString, String(parts[0]), workspaceToken: String(parts[1]))
                    }
                } else {
                    onError(reason)
                }
            }
        } catch {
            return false
        }
        return true
    }
    
    public func makePull(_ sessionId: String, token: String, onError: @escaping (String?) -> ()) -> Bool {
        guard let session = sessions[sessionId] else {
            return false
        }
        do {
            try session.sendPull(token) { [weak self] _, response, reason, atom in
                if response == 0 {
                    // make a subscriber
                    if let session = self?.sessions[sessionId] {
                        let parts = token.split(separator: "/") // We know this has 3 parts because it will have been verified by sendPull
                        session.makeSubscriber(String(parts[2]), String(parts[0]), workspaceToken: String(parts[1]))
                    }
                } else {
                    onError(reason)
                }
            }
        } catch {
            return false
        }
        return true
    }
    
    public func close(_ sessionId: String, publisher: String) {
        if let session = self.sessions[sessionId]?.publishSessions.first(where: {
            if let uuid = $0.value.value?.uuid(), uuid == publisher {
                return true
            }
            return false
        }) {
            session.value.value?.close()
        }
    }
    
    public func close(_ sessionId: String, subscriber: String) {
        if let session = self.sessions[sessionId]?.subscribeSessions.first(where: {
            if let uuid = $0.value.value?.uuid(), uuid == subscriber {
                return true
            }
            return false
        }) {
            session.value.value?.close()
        }
    }
    
    public func close(_ sessionId: String) {
        DispatchQueue.global().async {
            self.sessions.removeValue(forKey: sessionId)
        }
    }
    private var channel: Channel?
    private let fnStreamEstablished: LiveOnConnection
    private let fnConnection: (String) -> ()
    private let fnEnded: LiveOnEnded
    private let fnFormatQuery: (String, String?) -> [MediaFormat]?
    private let clock: Clock
    private var server: EventLoopFuture<Channel>?
    private var sessions: [String:FlavorSession]
}

fileprivate protocol FlavorMediaSession {
    func close() -> ()
    func removeTracks(_ tracks: [Int32]) -> Bool
    func setTracks(_ tracks: [(MediaFormat, Int32, Data?)]) // media format, track id, extradata
    func hasTrack(_ track: Int32) -> Bool
}

fileprivate class FlavorSession {
    // (callId, responseCode, reason?, child?)
    typealias RpcHandler = (Int32, Int32, String?, FlavorAtom?) -> ()

    fileprivate init(_ clock: Clock, 
        conn: Connection,
        dialedOut: Bool,
        sessionId: String? = nil,
        formatQuery: @escaping (String, String?) -> [MediaFormat]?,
        onEnded: @escaping LiveOnEnded, 
        onStreamEstablished: @escaping LiveOnConnection,
        onConnection: @escaping (Bool) -> ()) {
        self.fnStreamEstablished = onStreamEstablished
        self.fnStreamEnded = onEnded
        self.fnFormatQuery = formatQuery
        self.fnConnected = onConnection
        let sessionId = sessionId ?? UUID().uuidString
        self.sessionId = sessionId
        self.context = flavor.Context()
        self.publishSessions = [Int32: Weak<FlavorPublisher>]()
        self.subscribeSessions = [Int32: Weak<FlavorSubscriber>]()
        self.conn = conn
        self.clock = clock
        self.rpcCallId = 0
        self.trackId = 0
        self.dialedOut = dialedOut
        self.queue = DispatchQueue(label: sessionId)
        let bus = HeterogeneousBus()
        self.bus = bus
        self.connIn = conn >>> mix() >>> bus
        self.connOut = bus <<| filter() >>> conn
        self.inflightRpcHandler = [Int32:RpcHandler]()
        self.handler = bus <<| filter() >>> assetFilter(conn.ident)
            >>> Tx<NetworkEvent, ResultEvent> { [weak self] sample in 
                guard let strongSelf = self else {
                    return .gone
                }
                strongSelf.queue.async {
                    _ = strongSelf.handlePacket(sample)
                }
                return .nothing(sample.info())
            }

        if !dialedOut {
            sendPing { [weak self] _, result, _, _ in
                self?.fnConnected(result != 0)
            }
        }
    }

    deinit {
        disconnect()
    }

    func disconnect() {
        print("publish deinit")
        publishSessions.forEach {
            $0.value.value?.close()
        }
        subscribeSessions.forEach {
            $0.value.value?.close()
        }
        self.conn.close()
    }

    func sendPing(handler: RpcHandler? = nil) {
        do {
            let callId = self.rpcCallId
            self.rpcCallId = self.rpcCallId &+ 1
            let atom = flavor.RpcAtom(.sync, callId, command: .ping)
            let bytes = try flavor.serialize(atom)
            let event = NetworkEvent(time: nil, assetId: sessionId, workspaceId: "session", bytes: bytes)
            let tx: Terminal<NetworkEvent> = mix() >>> self.bus
            _ = .just(event) >>- tx
            if let handler = handler {
                self.inflightRpcHandler[callId] = handler
            }
        } catch(let error) {
            print("Caught error \(error)")
        }
    }

    func sendPush(_ token: String, handler: RpcHandler? = nil) throws {
        let callId = self.rpcCallId
        self.rpcCallId = self.rpcCallId &+ 1
        let maxSession: Int32 = zip(self.publishSessions.keys, self.subscribeSessions.keys).reduce(Int32(0)) { max($0, $1.0) }
        let streamId = (maxSession + 1)
        let child = try flavor.BasicAtom(.list([
            try flavor.BasicAtom(.in32(streamId), .in32),
            try flavor.BasicAtom(.utf8(token), .utf8)
            ]), .list)
        let atom = flavor.RpcAtom(.sync, callId, command: .push, child: child)
        let bytes = try flavor.serialize(atom)
        let event = NetworkEvent(time: nil, assetId: sessionId, workspaceId: "session", bytes: bytes)
        let tx: Terminal<NetworkEvent> = mix() >>> self.bus
        _ = .just(event) >>- tx
        if let handler = handler {
            self.inflightRpcHandler[callId] = handler
        }
    }

    func sendPull(_ token: String, handler: RpcHandler? = nil) throws {
        let callId = self.rpcCallId
        self.rpcCallId = self.rpcCallId &+ 1
        let maxSession: Int32 = zip(self.publishSessions.keys, self.subscribeSessions.keys).reduce(Int32(0)) { max($0, $1.0) }
        let streamId = (maxSession + 1)
        let child = try flavor.BasicAtom(.list([
            try flavor.BasicAtom(.in32(streamId), .in32),
            try flavor.BasicAtom(.utf8(token), .utf8)
            ]), .list)
        let atom = flavor.RpcAtom(.sync, callId, command: .pull, child: child)
        let bytes = try flavor.serialize(atom)
        let event = NetworkEvent(time: nil, assetId: sessionId, workspaceId: "session", bytes: bytes)
        let tx: Terminal<NetworkEvent> = mix() >>> self.bus
        _ = .just(event) >>- tx
        if let handler = handler {
            self.inflightRpcHandler[callId] = handler
        }
    }

    func sendRmTrak( _ tracks: [Int32], handler: RpcHandler? = nil) throws {
        let callId = self.rpcCallId
        self.rpcCallId = self.rpcCallId &+ 1
        let list = try tracks.map {
            try flavor.BasicAtom(.in32($0), .in32)
        }
        let atom = flavor.RpcAtom(.asyn, callId, command: .rmtk, child: try flavor.BasicAtom(.list(list), .list))
        let bytes = try flavor.serialize(atom)
        let event = NetworkEvent(time: nil, assetId: sessionId, workspaceId: "session", bytes: bytes)
        let tx: Terminal<NetworkEvent> = mix() >>> self.bus
        _ = .just(event) >>- tx
        if let handler = handler {
            self.inflightRpcHandler[callId] = handler
        }
    }

    func writeTrakAtom(_ codec: flavor.FourCC,
                        _ streamId: Int32,
                        _ trackId: Int32,
                        _ scale: Int64,
                        _ usesDts: Bool,
                        extradata: Data? = nil,
                        handler: RpcHandler? = nil) throws -> Int32 {

        let callId = self.rpcCallId
        self.rpcCallId = self.rpcCallId &+ 1
        let trak = try flavor.TrakAtom(codec, streamId, trackId, scale, usesDts, extradata)
        let atom = flavor.RpcAtom(.asyn, callId, command: .mdia, child: try flavor.BasicAtom(.list([trak]), .list))
        let bytes = try flavor.serialize(atom)
        let event = NetworkEvent(time: nil, assetId: sessionId, workspaceId: "session", bytes: bytes)
        let tx: Terminal<NetworkEvent> = mix() >>> self.bus
        _ = .just(event) >>- tx
        if let handler = handler {
            self.inflightRpcHandler[callId] = handler
        }
        return trackId
    }

    func sendReply(_ callId: Int32, _ responseCode: Int32, payload: flavor.BasicAtom? = nil) throws {
        let atom = flavor.RpcAtom(.rply, callId, responseCode: responseCode, child: payload)
        let bytes = try flavor.serialize(atom)
        let event = NetworkEvent(time: nil, assetId: sessionId, workspaceId: "session", bytes: bytes)
        let tx: Terminal<NetworkEvent> = mix() >>> self.bus
        _ = .just(event) >>- tx
    }

    func makePublisher( _ assetId: String, 
            _ workspaceId: String, 
            workspaceToken: String? = nil, 
            callId: Int32? = nil,
            streamId: Int32? = nil,
            formats: [MediaFormat] = [MediaFormat]()) {
        let maxSession: Int32 = zip(self.publishSessions.keys, self.subscribeSessions.keys).reduce(Int32(0)) { max($0, $1.0) }
        let streamId = streamId ?? (maxSession + 1)
        guard self.publishSessions[streamId] == nil else {
            return
        }
        let fnEnded = self.fnStreamEnded
        let pub = FlavorPublisher(self.clock, 
                        formats: formats,
                        bus: self.bus,
                        streamId: streamId,
                        dialedOut: self.dialedOut,
                        assetId: assetId,
                        workspaceId: workspaceId,
                        workspaceToken: workspaceToken,
                        onEnded: { [weak self] assetId, tracks in
                                DispatchQueue.global().async { fnEnded(assetId) }
                                guard let strongSelf = self else {
                                    return 
                                }
                                do {
                                    try strongSelf.sendRmTrak(tracks)
                                } catch {}
                                strongSelf.publishSessions.removeValue(forKey: streamId)
                            }) { [weak self] (type, streamId, trackId, scale, usesDts, data) in
            guard let strongSelf = self else {
                return -1
            }
            let trackId = trackId ?? strongSelf.trackId
            strongSelf.trackId = strongSelf.trackId &+ 1
            do {
                return try strongSelf.writeTrakAtom(type, streamId, trackId, scale, usesDts, extradata: data)
            } catch {
                return -1
            }
        }
        self.publishSessions[streamId] = Weak(value: pub)
        _ = self.fnStreamEstablished(pub, nil).andThen { [weak self] in
            do {
                guard case .success(let result) = $0, result == true else {
                    if let callId = callId {
                        try self?.sendReply(callId, -2, payload: try flavor.BasicAtom(.dict(["reason":
                            try flavor.BasicAtom(.utf8("Not allowed"), .utf8)]), .dict))
                    }
                    return
                } 
                if let callId = callId {
                    try self?.sendReply(callId, 0)
                }
            } catch {}
        }
    }

    func makeSubscriber( _ assetId: String, 
            _ workspaceId: String, 
            workspaceToken: String? = nil,
            callId: Int32? = nil,
            streamId: Int32? = nil,
            formats: [MediaFormat] = [MediaFormat]()) {
        let maxSession: Int32 = zip(self.publishSessions.keys, self.subscribeSessions.keys).reduce(Int32(0)) { max($0, $1.0) }
        let streamId = streamId ?? (maxSession + 1)
        guard self.subscribeSessions[streamId] == nil else {
            return
        }
        let fnEnded = self.fnStreamEnded
        let sub = FlavorSubscriber(self.clock, 
                        formats: [],
                        dialedOut: self.dialedOut,
                        assetId: assetId,
                        workspaceId: workspaceId,
                        workspaceToken: workspaceToken) { [weak self] assetId, tracks in
                            DispatchQueue.global().async { fnEnded(assetId) }
                            guard let strongSelf = self else {
                                return 
                            }
                            do {
                                try strongSelf.sendRmTrak(tracks)
                            } catch {
                                print("Exception while sending rmtrak \(error)")
                            }
                            strongSelf.subscribeSessions.removeValue(forKey: streamId)
                        }
        self.subscribeSessions[streamId] = Weak(value: sub)
        _ = self.fnStreamEstablished(nil, sub).andThen { [weak self] in
            do {
                guard case .success(let result) = $0, result == true else {
                    if let callId = callId { 
                        try self?.sendReply(callId, -2, payload: try flavor.BasicAtom(.dict(["reason":
                            try flavor.BasicAtom(.utf8("Not allowed 🤔"), .utf8)]), .dict))
                    }
                    return
                } 
                if let callId = callId {
                    try self?.sendReply(callId, 0)
                }
            } catch {
                print("Exception in stream establish \(error)")
            }
        }
    }
    
    func handleMedia(_ atom: flavor.MediaAtom) {
        let trackId = atom.trackId
        let session = self.subscribeSessions.values.first {
            guard let sub = $0.value else {
                return false
            }
            return sub.hasTrack(trackId)
        }
        if let session = session?.value {
            session.recv(atom)
        }
    }
    private func getStreamTokens(_ atom: flavor.RpcAtom) throws -> ([String], Int32) {
        let callId = atom.callId
        guard let payload = atom.child as? flavor.BasicAtom,
            case .list(let list) = payload.value else {
                try sendReply(callId, -3, payload: try flavor.BasicAtom(.dict(["reason":
                    try flavor.BasicAtom(
                        .utf8("missing property list"), .utf8)
                    ]), .dict))
                throw flavor.FlavorError.invalidContainerAtomTypeCombination
        }
        guard let tokenAtom = list[safe: 1] as? flavor.BasicAtom,
            case .utf8(let token) = tokenAtom.value else {
                try sendReply(callId, -3, payload: try flavor.BasicAtom(.dict(["reason":
                    try flavor.BasicAtom(
                        .utf8("missing token atom"), .utf8)
                    ]), .dict))
                throw flavor.FlavorError.invalidContainerAtomTypeCombination
        }
        guard let streamAtom = list[safe: 0] as? flavor.BasicAtom,
            case .in32(let streamId) = streamAtom.value else {
                try sendReply(callId, -3, payload: try flavor.BasicAtom(.dict(["reason":
                    try flavor.BasicAtom(
                        .utf8("missing streamId atom"), .utf8)
                    ]), .dict))
                throw flavor.FlavorError.invalidContainerAtomTypeCombination
        }
        let parts = token.split(separator:"/").map(String.init)
        return (parts, streamId)
    }
    func handleRpc( _ atom: flavor.RpcAtom) {
        if let command = atom.command {
            switch command {
                case .ping: do {
                    let reply = flavor.RpcAtom(.rply, atom.callId, responseCode: 0)
                    let bytes = try flavor.serialize(reply)
                    let event = NetworkEvent(time: nil, assetId: sessionId, workspaceId: "session", bytes: bytes)
                    let tx  : Terminal<NetworkEvent> = mix() >>> self.bus
                    _ = .just(event) >>- tx
                    if atom.callId == 0 && self.dialedOut {
                        self.fnConnected(true)
                    }
                }  catch (let error) {
                    print("Caught error \(error)")
                }
                case .mdia: ()
                    // handle trak
                    guard let payload = atom.child as? flavor.BasicAtom,
                        case .list(let atoms) = payload.value else { return }
                    for ftrak in atoms {
                        guard let trak = ftrak as? flavor.TrakAtom else {
                            return
                        }
                        self.context.tracks[trak.trackId] = flavor.Track(usesDts: trak.usesDts, scale: trak.scale)
                        let streamId = trak.streamId
                        let session = self.subscribeSessions[streamId]
                        if let session = session?.value { do {
                            let format = try flavor.fourccToMediaFormat(trak.codec)
                            var extraData: Data? = nil
                            if case .data(let data)? = trak.extraData?.value {
                                extraData = data
                            }
                            session.setTracks([(format, trak.trackId, extraData)])
                            } catch {}
                        }
                    }
                case .pull:
                    do {
                        let callId = atom.callId
                        let (parts, streamId) = try getStreamTokens(atom)
                        guard parts.count == 3 else {
                            // incorrect token format
                            try sendReply(callId, -1, payload: try flavor.BasicAtom(.dict(["reason":
                                try  flavor.BasicAtom(
                                    .utf8("incorrect token format, should be {workspaceId}/{workspaceToken}/{assetId}"), .utf8)
                                ]), .dict))
                            return
                        }
                        let formats = self.fnFormatQuery(parts[2], parts[0])
                        self.makePublisher(parts[2], parts[0], workspaceToken: parts[1], callId: callId, streamId: streamId, formats: formats ?? [MediaFormat]())
                    } catch {
                        print("caught error \(error)")
                        return
                    }
                case .push:
                    do {
                        let callId = atom.callId
                        let (parts, streamId) = try getStreamTokens(atom)
                        guard parts.count == 2 else {
                            // incorrect token format
                            try sendReply(callId, -1, payload: try flavor.BasicAtom(.dict(["reason":
                                try  flavor.BasicAtom(
                                    .utf8("incorrect token format, should be {workspaceId}/{workspaceToken}"), .utf8)
                                ]), .dict))
                            return
                        }
                        self.makeSubscriber(UUID().uuidString, parts[0], workspaceToken: parts[1], callId: callId, streamId: streamId)
                    } catch {
                        return
                    }
                case .rmtk:
                    guard let payload = atom.child as? flavor.BasicAtom,
                        case .list(let atoms) = payload.value else { return }
                    let tracks: [Int32] = atoms.compactMap { atom in
                        guard let basic = atom as? flavor.BasicAtom, case .in32(let trackId) = basic.value else {
                            return nil
                        }
                        return trackId
                    }
                    let publishSessions = self.publishSessions
                    publishSessions.forEach { session in 
                        if let hasTracks = session.1.value?.removeTracks(tracks), !hasTracks{
                            session.1.value?.close()
                        }
                    }
                    let subscribeSessions = self.subscribeSessions
                    subscribeSessions.forEach { session in 
                        if let hasTracks = session.1.value?.removeTracks(tracks), !hasTracks{
                            session.1.value?.close()
                        }
                    }
                default: ()
            }
        } else if let responseCode = atom.responseCode {
            switch atom.type() {
                case .rply:
                if let handler = self.inflightRpcHandler[atom.callId] {
                    let reason: String? = atom.child <??> {
                        if let basic = $0 as? flavor.BasicAtom,
                            case .dict(let dict) = basic.value,
                            let reason = dict["reason"] as? flavor.BasicAtom,
                            case .utf8(let reasonStr) = reason.value {
                                return reasonStr
                            }
                        return nil
                    } <|> nil
                    handler(atom.callId, responseCode, reason, atom.child)
                    self.inflightRpcHandler.removeValue(forKey: atom.callId)
                }
                default: ()
            }
        }
    }

    func handlePacket(_ event: NetworkEvent) -> EventBox<ResultEvent> {
        var data = accumulator <??> { buffer.concat($0, event.data()) ?? event.data() } <|> event.data()
        do {
            repeat {
                let base = try flavor.parse(data, ctx: self.context)
                switch base.0.containerType() {
                    case .rpc:
                        // handle in session
                        if let atom = base.0 as? flavor.RpcAtom {
                            handleRpc(atom)
                        }
                    case .media: ()
                        // handle media
                        if let atom = base.0 as? flavor.MediaAtom {
                            handleMedia(atom)
                        }
                    default: () // find appropriate track to handle
                }
                data = base.1
            } while (data.readableBytes > 0)
            accumulator = nil
        } catch let error as flavor.FlavorError {
            switch error {
                case .unknownAtom(_, let size):
                    data.moveReaderIndex(forwardBy: Int(size))
                    accumulator = data
                    return .nothing(event.info())
                case .malformedAtom(let type, let size):
                    print("malformed atom, skip \(size) and send error to peer via async command")
                    data.moveReaderIndex(forwardBy: Int(size))
                    accumulator = data
                    return .error(EventError("flavor.parse", -4, "Malformed atom 4CC (\(type))"))
                case .incompleteBuffer:
                    //print("buffer incomplete")
                    accumulator = data
                    return .nothing(event.info())
                case .unknownCommand(let command):
                    print("unknown command, advance reader and respond with an error code")
                    return .error(EventError("flavor.parse", -3, "Unknown command 4CC (\(command))"))
                default: 
                    print("other error \(error)")
                    return .error(EventError("flavor.parse", -1, "\(error)"))
            }
        } catch {
            return .error(EventError("flavor.parse", -2, "\(error)"))
        }
        
        return .nothing(event.info())
    }
    let queue: DispatchQueue
    let fnFormatQuery: (String, String?) -> [MediaFormat]?
    let dialedOut: Bool
    let fnStreamEnded: LiveOnEnded
    let fnStreamEstablished: LiveOnConnection
    let fnConnected: (Bool) -> ()
    let connIn: Terminal<NetworkEvent>
    let connOut: Tx<Event, NetworkEvent>
    var context: flavor.Context
    var handler: Tx<Event, ResultEvent>? = nil
    let clock: Clock
    let conn: Connection
    let bus: HeterogeneousBus
    let sessionId: String
    var rpcCallId: Int32
    var trackId: Int32
    var inflightRpcHandler: [Int32: RpcHandler]
    var publishSessions: [Int32: Weak<FlavorPublisher>]
    var subscribeSessions: [Int32: Weak<FlavorSubscriber>]
    var accumulator: ByteBuffer? = nil
}

fileprivate class FlavorPublisher: Terminal<CodedMediaSample>, FlavorMediaSession, LivePublisher {
    
    public init(_ clock: Clock, 
                 formats: [MediaFormat],
                 bus: HeterogeneousBus,
                 streamId: Int32,
                 dialedOut: Bool,
                 assetId: String, 
                 workspaceId: String, 
                 workspaceToken: String?,
                 onEnded: @escaping (String, [Int32]) -> (),
                 writeTrakAtom: @escaping (flavor.FourCC, Int32, Int32?, Int64, Bool, Data?) -> Int32) { // codec name, stream id, track id (maybe, assign=nil), time base, uses dts, extradata, returns track id
        self.idAsset = assetId
        self.ident = UUID().uuidString
        self.idWorkspace = workspaceId
        self.tokenWorkspace = workspaceToken
        self.formats = formats
        self.clock = clock
        self.didDialOut = dialedOut
        self.bus = bus
        self.writeTrakAtom = writeTrakAtom
        self.tracks = [MediaFormat: (Int32, Data?)]()
        self.streamId = streamId
        self.onEnded = onEnded
        self.ignore = Set<MediaFormat>()
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            do { 
                if strongSelf.tracks[sample.mediaFormat()] == nil && !strongSelf.ignore.contains(sample.mediaFormat()) {
                    // send a trak atom
                    let fourcc = try flavor.mediaFormatToFourcc(sample.mediaFormat())
                    let trackId = writeTrakAtom(fourcc, streamId, nil, sample.pts().scale, true, sample.sideData()["config"])
                    
                    print("writing track atom, id=\(trackId) scale=\(sample.pts().scale)")
                    strongSelf.tracks[sample.mediaFormat()] = (trackId, sample.sideData()["config"])
                }
                guard let trackId = strongSelf.tracks[sample.mediaFormat()]?.0 else {
                    return .nothing(sample.info())
                }
                let atom = try flavor.MediaAtom(sample.data(), trackId, sample.pts().scale, sample.pts(), dts: sample.dts())
                let bytes = try flavor.serializeMedia(atom)

                let event = NetworkEvent(time: clock.current(), 
                        assetId: strongSelf.idAsset, 
                        workspaceId: strongSelf.idWorkspace, 
                        workspaceToken: strongSelf.tokenWorkspace, 
                        bytes: bytes)
                let tx: Terminal<NetworkEvent> = mix() >>> strongSelf.bus
                return .just(event) >>- tx
            } catch (let error) {
                return .error(EventError("flavor.publish", -1, "Serialization error \(error)"))
            }
        }
    }
    deinit {
        close()
    }
    func close() {
        let tracks = self.tracks.map { $1.0 }
        self.onEnded(uuid(), tracks)
    }
    func setTracks(_ tracks: [(MediaFormat, Int32, Data?)]) {
        for track in tracks {
            self.ignore.remove(track.0)
            self.tracks[track.0] = (track.1, track.2)
        }
    }
    func removeTracks(_ tracks: [Int32]) -> Bool {
        tracks.forEach {
            for (key, val) in self.tracks {
                if val.0 == $0 {
                    self.ignore.insert(key)
                }
            }
        }
        self.tracks = self.tracks.filter { !tracks.contains($1.0) }
        return self.tracks.count > 0
    }
    func hasTrack( _ track: Int32) -> Bool {
        for val in self.tracks.values {
            if val.0 == track {
                return true
            }
        }
        return false
    }
    func liveType() -> MediaSourceType {
        return .flavor
    }
    func assetId() -> String {
        return self.idAsset
    }
    func uuid() -> String {
        return self.ident
    }
    func workspaceId() -> String {
        return self.idWorkspace
    }
    func workspaceToken() -> String? {
        return self.tokenWorkspace
    }
    func dialedOut() -> Bool {
        return self.didDialOut
    }
    func acceptedFormats() -> [MediaFormat] {
        let formats = self.formats
        print("Publisher acceptedFormats query, returning \(formats)")
        return formats
    }
    func uri() -> String? { return nil }
    let writeTrakAtom: (flavor.FourCC, Int32, Int32?, Int64, Bool, Data) -> Int32
    let formats: [MediaFormat]
    let didDialOut: Bool
    let streamId: Int32
    let ident: String
    let idAsset: String
    let idWorkspace: String
    let tokenWorkspace: String?
    let clock: Clock
    let bus: HeterogeneousBus
    let onEnded: (String, [Int32]) -> ()
    var ignore: Set<MediaFormat>
    var tracks: [MediaFormat: (Int32, Data?)] // trackId, extradata
}

fileprivate class FlavorSubscriber: Source<CodedMediaSample>, FlavorMediaSession, LiveSubscriber {
    public init(_ clock: Clock, 
                 formats: [MediaFormat],
                 dialedOut: Bool,
                 assetId: String, 
                 workspaceId: String, 
                 workspaceToken: String?,
                 onEnded: @escaping (String, [Int32]) -> ()) {
        self.idAsset = assetId
        self.idWorkspace = workspaceId
        self.tokenWorkspace = workspaceToken
        self.formats = formats
        self.clock = clock
        self.didDialOut = dialedOut
        self.tracks = [Int32: (MediaFormat, Data?)]()
        self.onEnded = onEnded
        super.init()
    }

    deinit {
        print("FlavorSubscriber deinit")
        close()
    }
    func close() {
        print("FlavorSubscriber close \(assetId())")
        let tracks = self.tracks.map { $0.0 }
        self.onEnded(assetId(), tracks)
    }
    func setTracks(_ tracks: [(MediaFormat, Int32, Data?)]) {
        for track in tracks {
            self.tracks[track.1] = (track.0, track.2)
        }
    }
    func removeTracks(_ tracks: [Int32]) -> Bool {
        self.tracks =  self.tracks.filter { !tracks.contains($0.0) }
        return self.tracks.count > 0
    }
    func hasTrack( _ track: Int32) -> Bool {
        return tracks[track] != nil
    }
    func liveType() -> MediaSourceType {
        return .flavor
    }
    func assetId() -> String {
        return self.idAsset
    }
    func uuid() -> String {
        return self.idAsset
    }
    func workspaceId() -> String {
        return self.idWorkspace
    }
    func workspaceToken() -> String? {
        return self.tokenWorkspace
    }
    func dialedOut() -> Bool {
        return self.didDialOut
    }
    func suppliedFormats() -> [MediaFormat] {
        let formats: [MediaFormat] = [.avc, .aac, .opus, .hevc, .vp8, .vp9] //tracks.map { $1.0 }
        return formats
    }
    func recv(_ sample: flavor.MediaAtom) {
        guard case .data(let data) = sample.data.value, let track = tracks[sample.trackId] else {
            return
        }
        let format = track.0
        let type: MediaType = [.aac, .opus].contains(format) ? .audio: .video
        let extra = track.1.map { ["config": $0] }
        let mediaSample = CodedMediaSample(assetId(), workspaceId(), clock.current(), sample.pts, sample.dts, type, format, data, extra, nil)
        _ = self.emit(mediaSample)
    }
    var tracks: [Int32: (MediaFormat, Data?)]
    let formats: [MediaFormat]
    let didDialOut: Bool
    let idAsset: String
    let idWorkspace: String
    let tokenWorkspace: String?
    let onEnded: (String, [Int32]) -> ()
    let clock: Clock
}

public enum FlavorAtomContainerType {
    case basic
    case rpc
    case media
    case track
}
public protocol FlavorAtom {
    func size() -> Int32
    func type() -> flavor.FourCC
    func containerType() -> FlavorAtomContainerType
}

public enum flavor {
    public enum FlavorError: Error {
        case incompleteBuffer
        case unknownAtom(Int32, Int32)
        case unknownCommand(Int32)
        case malformedAtom(Int32, Int32)
        case invalidContainerAtomTypeCombination
        case mediaMissingTrak
        case rpcCommandMissing
        case unknownCodec(Int32)
        case unknown
    }
    
    struct Track {
        let usesDts: Bool
        let scale: Int64
    }

    struct Context {
        var tracks: [Int32: Track] = [Int32:Track]()
    }

    public enum FourCC : Int32 {
        // basic datatype atoms
        case in32 = 0x696E3332 // int32 atom
        case in64 = 0x696E3634 // int64 atom
        case fl32 = 0x666C3332 // float32 atom
        case fl64 = 0x666C3634 // float64 atom
        case bool = 0x626F6F6C // bool atom
        case data = 0x64617461 // data atom
        case utf8 = 0x75746638 // utf8 atom
        case dict = 0x64696374 // dict atom
        case list = 0x6C697374 // list atom


        // rpc atoms
        case sync = 0x73796E63 // sync rpc command atom
        case asyn = 0x6173796E // async rpc command atom
        case rply = 0x72706C79 // rpc command reply atom

        // rpc commands
        case ping = 0x70696E67 // ping command (not an atom)
        case meta = 0x6D657461 // used for sending encoder metadata
        case push = 0x70757368 // push a stream
        case pull = 0x70756C6C // pull a stream
        case rmtk = 0x726D746B // remove tracks
        case err_ = 0x65727221 // 'err!' error command (not an atom)
        
        // specialized atoms
        case mdia = 0x6D646961 // media data atom (also used as an rpc command)
        case trak = 0x7472616B // track header atom
        case tokn = 0x746F6B6E // stream identifier atom (same as utf8)
        
        // codecs
        case AVC1 = 0x41564331 // H.264/AVC
        case HVC1 = 0x48564331 // HEVC
        case AV10 = 0x61763120
        case VP80 = 0x56503830
        case VP90 = 0x56503930
        case OPUS = 0x4F505553
        case MP4A = 0x4D503441 // AAC
        
    }
    
    static func parse(_ bytes: ByteBuffer, ctx: Context) throws -> (FlavorAtom, ByteBuffer) {
        guard var buf = buffer.getSlice(bytes, bytes.readableBytes), 
            buf.readableBytes >= 8 else {
            throw FlavorError.incompleteBuffer
        }
        guard let size: Int32 = buf.readInteger(endianness: .little),
            size - 8 >= 0 && buf.readableBytes >= (size - 4) else {
            throw FlavorError.incompleteBuffer
        }
        let typeValue = buf.readInteger(endianness: .little, as: Int32.self)
        let maybeType = typeValue <??> { FourCC(rawValue: $0) } <|> nil
        guard let type = maybeType else {
            if let typeValue = typeValue {
                throw FlavorError.unknownAtom(typeValue, size)
            } else {
                throw FlavorError.incompleteBuffer
            }
        }

        let atom: FlavorAtom? = try { switch type {
            case .in32:
                return try buf.readInteger(endianness: .little, as: Int32.self).map { try BasicAtom(.in32($0), type) }
            case .in64:
                return try buf.readInteger(endianness: .little, as: Int64.self).map { try BasicAtom(.in64($0), type) }
            case .fl32:
                return try buf.readInteger(endianness: .little, as: UInt32.self).map { try BasicAtom(.fl32(Float(bitPattern: $0)), type) }
            case .fl64:
                return try buf.readInteger(endianness: .little, as: UInt64.self).map { try BasicAtom(.fl64(Double(bitPattern: $0)), type) }
            case .utf8, .tokn:
                return try buf.readString(length: Int(size - 8)).map { try BasicAtom(.utf8($0), type) }
            case .bool:
                return try buf.readBytes(length: 1)?[safe:0].map { try BasicAtom(.bool($0 != 0), type) }
            case .data:
                return try buf.readBytes(length: Int(size)-8).map { try BasicAtom(.data(Data($0)), type) }
            case .list:
                let start = buf.readableBytes
                var current = start
                var list = [FlavorAtom]()
                while (start - current) < Int(size - 8) {
                    let (atom, next) = try parse(buf, ctx: ctx)
                    list.append(atom)
                    current = next.readableBytes
                    buf = next
                }
                return try BasicAtom(.list(list), type)
            case .dict:
                let start = buf.readableBytes
                var current = start
                var dict = [String:FlavorAtom]()
                while (start - current) < Int(size - 8) {
                    let (key, next) = try parse(buf, ctx: ctx)
                    let (value, nextb) = try parse(next, ctx: ctx)
                    guard let kvalue = (key as? BasicAtom)?.value,
                        case .utf8(let kstr) = kvalue else {
                        throw FlavorError.malformedAtom(type.rawValue, size)
                    }
                    dict[kstr] = value
                    current = nextb.readableBytes
                    buf = nextb
                }
                return try BasicAtom(.dict(dict), type)
            case .sync, .asyn, .rply:
                let (atom, next) = try parseRpc(buf, size, type, ctx: ctx)
                buf = next
                return atom
            case .mdia:
                let (atom, next) = try parseMedia(buf, size, type, ctx: ctx)
                buf = next
                return atom
            case .trak:
                let (atom, next) = try parseTrack(buf, size, type, ctx: ctx)
                buf = next
                return atom
            default: return nil
        } }()
        if let atom = atom {
            return (atom, buf)
        } else {
            throw FlavorError.unknownAtom(type.rawValue, size)
        }
    }
    
    static func parseRpc(_ buf: ByteBuffer, _ size: Int32, _ type: FourCC, ctx: Context) throws -> (FlavorAtom, ByteBuffer) {
        guard var buf = buffer.getSlice(buf, buf.readableBytes) else { // already took first 8 bytes in size and type
            throw FlavorError.incompleteBuffer
        }
        guard let callId = buf.readInteger(endianness: .little, as: Int32.self) else {
            throw FlavorError.incompleteBuffer
        }
        guard let fourcc = buf.readInteger(endianness: .little, as: Int32.self) else {
            throw FlavorError.incompleteBuffer
        }
        if type != .rply {
            guard let command = FourCC(rawValue: fourcc) else {
                throw FlavorError.unknownCommand(fourcc)
            }
            if (size &- 8) > 8 {
                // we (should) have a payload atom
                let (atom, next) = try parse(buf, ctx: ctx)
                return (RpcAtom(type, callId, command: command, child: atom), next)
            }
            return (RpcAtom(type, callId, command: command), buf)
        } else {
            if (size &- 8) > 8 {
                // we (should) have a payload atom
                let (atom, next) = try parse(buf, ctx: ctx)
                return (RpcAtom(type, callId, responseCode: fourcc, child: atom), next)
            }
            return (RpcAtom(type, callId, responseCode: fourcc), buf)
        }
        
    }

    static func parseMedia(_ buf: ByteBuffer, _ size: Int32, _ type: FourCC, ctx: Context) throws -> (FlavorAtom, ByteBuffer) {
        guard var buf = buffer.getSlice(buf, buf.readableBytes) else { // already took first 8 bytes in size and type
            throw FlavorError.incompleteBuffer
        }

        guard let trackId = buf.readInteger(endianness: .little, as: Int32.self) else {
            throw FlavorError.incompleteBuffer
        }

        guard let pts = buf.readInteger(endianness: .little, as: Int64.self) else {
            throw FlavorError.incompleteBuffer
        }

        guard let track = ctx.tracks[trackId] else {
            throw FlavorError.mediaMissingTrak
        }
        var dts: TimePoint? = nil
        if track.usesDts == true {
            if let val = buf.readInteger(endianness: .little, as: Int64.self)  {
                dts = TimePoint(val, track.scale)
            } else { 
                throw FlavorError.incompleteBuffer 
            }
        }
        
        let (data, next) = try parse(buf, ctx: ctx)
        guard let dataAtom = data as? BasicAtom, case .data(let dataValue) = dataAtom.value else {
            throw FlavorError.malformedAtom(type.rawValue, size)
        }

        let atom = try MediaAtom(dataValue, trackId, track.scale, TimePoint(pts, track.scale), dts: dts)

        return (atom, next)
    }

    static func parseTrack(_ buf: ByteBuffer, _ size: Int32, _ type: FourCC, ctx: Context) throws -> (FlavorAtom, ByteBuffer) {
        guard var buf = buffer.getSlice(buf, buf.readableBytes) else { // already took first 8 bytes in size and type
            throw FlavorError.incompleteBuffer
        }
        
        guard let codecId = buf.readInteger(endianness: .little, as: Int32.self) else {
            throw FlavorError.incompleteBuffer
        }
        guard let streamId = buf.readInteger(endianness: .little, as: Int32.self) else {
            throw FlavorError.incompleteBuffer
        }
        guard let trackId = buf.readInteger(endianness: .little, as: Int32.self) else {
            throw FlavorError.incompleteBuffer
        }
        
        guard let timeBase = buf.readInteger(endianness: .little, as: Int64.self) else {
            throw FlavorError.incompleteBuffer
        }
        
        guard let usesDtsBytes = buf.readBytes(length: 1) else {
            throw FlavorError.incompleteBuffer
        }
        let usesDts = (usesDtsBytes[0] == 1)
        
        let (extradata, next) = try { () -> (FlavorAtom?, ByteBuffer) in
            if size > 25 {
                let vals = try parse(buf, ctx: ctx)
                return (vals.0, vals.1)
            }
            return  (nil, buf)
            }()
        
        let extravalue = try (extradata as? BasicAtom).map { (atom: BasicAtom) -> Data in
            guard case .data(let dataValue) = atom.value else {
                throw FlavorError.malformedAtom(type.rawValue, size)
            }
            return dataValue
        }
        guard let codec = FourCC(rawValue: codecId) else {
            throw FlavorError.unknownCodec(codecId)
        }
        let atom = try TrakAtom(codec, streamId, trackId, timeBase, usesDts, extravalue)
        
        return (atom, next)
    }
    
    static func serialize(_ atom: FlavorAtom) throws -> ByteBuffer {
        switch atom.containerType() {
        case .basic:
            return try serializeBasic(atom)
        case .rpc:
            return try serializeRpc(atom)
        case .media:
            return try serializeMedia(atom)
        case .track:
            return try serializeTrack(atom)
        }
    }

    static func serializeBasic(_ atom: FlavorAtom) throws -> ByteBuffer {
        let invalidTypes: [FourCC] = [.sync, .asyn, .rply, .mdia, .trak, .ping, .err_]
        guard !invalidTypes.contains(atom.type()) && atom.containerType() == .basic else {
            throw FlavorError.invalidContainerAtomTypeCombination
        }
        guard let atom = atom as? BasicAtom else {
            throw FlavorError.invalidContainerAtomTypeCombination
        }
        let size = atom.size()
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: Int(size))

        buf.writeInteger(size, endianness: .little)
        buf.writeInteger(atom.type().rawValue, endianness: .little)

        switch atom.value {
            case .in32(let val): 
                buf.writeInteger(val, endianness: .little)
            case .in64(let val):
                buf.writeInteger(val, endianness: .little)
            case .fl32(let val):
                buf.writeInteger(val.bitPattern, endianness: .little)
            case .fl64(let val):
                buf.writeInteger(val.bitPattern, endianness: .little)
            case .utf8(let val):
                buf.writeString(val)
            case .bool(let val):
                buf.writeBytes([val == true ? 0x1 : 0x0])
            case .data(let val):
                var data = buffer.fromData(val)
                buf.writeBuffer(&data)
            case .list(let val):
                try val.forEach {
                    var data = try serialize($0)
                    buf.writeBuffer(&data)
                }
            case .dict(let val):
                try val.forEach {
                    var key = try serialize(BasicAtom(.utf8($0.key), .utf8))
                    var value = try serialize($0.value)
                    buf.writeBuffer(&key)
                    buf.writeBuffer(&value)
                }
        }

        return buf
    }
    static func serializeRpc(_ atom: FlavorAtom) throws -> ByteBuffer {
        guard atom.containerType() == .rpc && [.asyn, .sync, .rply].contains(atom.type()) else {
            throw FlavorError.invalidContainerAtomTypeCombination
        }
        guard let atom = atom as? RpcAtom else {
            throw FlavorError.invalidContainerAtomTypeCombination
        }
        
        guard atom.command != nil || atom.responseCode != nil else {
            throw FlavorError.rpcCommandMissing
        }

        let size = atom.size()
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: Int(size))

        buf.writeInteger(size, endianness: .little)
        buf.writeInteger(atom.type().rawValue, endianness: .little)
        buf.writeInteger(atom.callId, endianness: .little)
        if let command = atom.command {
            buf.writeInteger(command.rawValue, endianness: .little)
        } else if let responseCode = atom.responseCode {
            buf.writeInteger(responseCode, endianness: .little)
        }
        
        if let child = atom.child,
           let buf = buffer.concat(buf, try serialize(child)) {
            return buf
        }
        return buf
    }

    static func serializeMedia(_ atom: FlavorAtom) throws -> ByteBuffer {
        guard atom.containerType() == .media && atom.type() == .mdia else {
            throw FlavorError.invalidContainerAtomTypeCombination
        }
        guard let atom = atom as? MediaAtom else {
            throw FlavorError.invalidContainerAtomTypeCombination
        }

        let size = atom.size()
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: Int(size))
        buf.writeInteger(size, endianness: .little)
        buf.writeInteger(atom.type().rawValue, endianness: .little)
        buf.writeInteger(atom.trackId, endianness: .little)
        buf.writeInteger(rescale(atom.pts, atom.scale).value, endianness: .little)
        if let dts = atom.dts {
            buf.writeInteger(rescale(dts, atom.scale).value, endianness: .little)
        }
        var media = try serializeBasic(atom.data)
        buf.writeBuffer(&media)
        return buf
    }

    static func serializeTrack(_ atom: FlavorAtom) throws -> ByteBuffer {
        guard atom.containerType() == .track && atom.type() == .trak else {
            throw FlavorError.invalidContainerAtomTypeCombination
        }
        guard let atom = atom as? TrakAtom else {
            throw FlavorError.invalidContainerAtomTypeCombination
        }

        let size = atom.size()
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: Int(size))
        buf.writeInteger(size, endianness: .little)
        buf.writeInteger(atom.type().rawValue, endianness: .little)
        buf.writeInteger(atom.codec.rawValue, endianness: .little)
        buf.writeInteger(atom.streamId, endianness: .little)
        buf.writeInteger(atom.trackId, endianness: .little)
        buf.writeInteger(atom.scale, endianness: .little)
        buf.writeBytes([atom.usesDts ? 1 : 0])
        if let extra = atom.extraData {
            var extradata = try serializeBasic(extra)
            buf.writeBuffer(&extradata)
        }
        return buf
    }

    struct BasicAtom : FlavorAtom {
        public enum Types {
            case in32(Int32)
            case in64(Int64)
            case fl32(Float)
            case fl64(Double)
            case utf8(String)
            case bool(Bool)
            case data(Data)
            case list([FlavorAtom])
            case dict([String:FlavorAtom])
        }
        public init(_ value: Types, _ type: FourCC) throws {
            let invalidTypes: [FourCC] = [.sync, .asyn, .rply, .mdia, .trak, .ping, .err_]
            if invalidTypes.contains(type) {
                throw FlavorError.invalidContainerAtomTypeCombination
            }
            self.type_ = type
            self.value = value
        }
        public func size() -> Int32 {
            switch value {
                case .in32(_), .fl32(_): return 8+4
                case .in64(_), .fl64(_): return 8+8
                case .bool(_): return 8+1
                case .data(let val): return Int32(8 + val.count)
                case .list(let val): return 8 + val.reduce(0) { $0 + $1.size() }
                case .dict(let val): return 8 + val.reduce(0) { $0 + $1.value.size() }
                case .utf8(let val): return Int32(8 + val.utf8.count)
            }
        }
        public func type() -> FourCC  {
            return type_
        }
        public func containerType() -> FlavorAtomContainerType {
            return .basic
        }
        let type_: FourCC
        let value: Types
    }

    struct RpcAtom: FlavorAtom {
        public init(_ type: FourCC, _ callId: Int32, command: FourCC? = nil, responseCode: Int32? = nil, child: FlavorAtom? = nil) {
            self.type_ = type
            self.callId = callId
            self.command = command
            self.responseCode = responseCode
            self.child = child
        }

        public func size() -> Int32 {
            return 8 /* header */ + 8 /* callId, second value */ + (child?.size() ?? 0)
        }

        public func type() -> FourCC {
            return type_
        }

        public func containerType() -> FlavorAtomContainerType {
            return .rpc
        }

        public func isAsync() -> Bool {
            return type_ == .asyn
        }

        public func isReply() -> Bool {
            return type_ == .rply
        }

        let type_: FourCC
        let callId: Int32
        let command: FourCC?
        let responseCode: Int32?
        let child: FlavorAtom?
    }

    struct MediaAtom: FlavorAtom {
        public init(_ data: Data, _ trackId: Int32, _ scale: Int64, _ pts: TimePoint, dts: TimePoint? = nil) throws {
            self.data = try BasicAtom(.data(data), .data)
            self.trackId = trackId
            self.scale = scale
            self.pts = pts
            self.dts = dts
        }

        public func size() -> Int32 {
            return 8 /* header */ + data.size() + 12 /* pts + trackId */ + (dts != nil ? 8 : 0)
        }

        public func type() -> FourCC {
            return .mdia
        }

        public func containerType() -> FlavorAtomContainerType {
            return .media
        }

        let trackId: Int32
        let pts: TimePoint
        let dts: TimePoint?
        let scale: Int64
        let data: BasicAtom
    }

    struct TrakAtom: FlavorAtom {
        public init(_ codec: FourCC, _ streamId: Int32, _ trackId: Int32, _ timeBase: Int64, _ usesDts: Bool, _ extra: Data?) throws {
            self.codec = codec
            self.trackId = trackId
            self.scale = timeBase
            self.usesDts = usesDts
            self.streamId = streamId
            if let extra = extra {
                self.extraData = try BasicAtom(.data(extra), .data)
            } else {
                self.extraData = nil
            }
        }

        public func size() -> Int32 {
            return 8 /* header */ + 17 /* codec(4) + trackId(4) + scale(8) + usesDts(1) */ + (extraData?.size() ?? 0)
        }

        public func type() -> FourCC {
            return .trak
        }

        public func containerType() -> FlavorAtomContainerType {
            return .track
        }

        let trackId: Int32
        let streamId: Int32
        let codec: FourCC
        let scale: Int64
        let usesDts: Bool
        let extraData: BasicAtom?
    }
    
    static func fourccToMediaFormat(_ val: FourCC) throws -> MediaFormat {
        switch val {
        case .AV10:
            return .av1
        case .AVC1:
            return .avc
        case .HVC1:
            return .hevc
        case .MP4A:
            return  .aac
        case .OPUS:
            return .opus
        case .VP80:
            return .vp8
        case .VP90:
            return .vp9
        default:throw FlavorError.unknownCodec(val.rawValue)
        }
    }
    
    static  func mediaFormatToFourcc(_ val: MediaFormat) throws -> FourCC {
        switch val {
        case .aac:
            return .MP4A
        case .av1:
            return .AV10
        case .avc:
            return .AVC1
        case .hevc:
            return .HVC1
        case .opus:
            return .OPUS
        case .vp8:
            return .VP80
        case .vp9:
            return .VP90
        default: throw FlavorError.unknownCodec(Int32(val.rawValue))
        }
    }
}




