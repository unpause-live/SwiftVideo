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
import Foundation
#if os(Linux)
import CSwiftVideo
#endif

#if os(macOS) || os(iOS) || os(tvOS)
import Darwin

func generateRandomBytes(_ base: UnsafeMutableRawPointer?, _ count: Int) {
    if let ptr = base {
        _ = SecRandomCopyBytes(kSecRandomDefault, count, ptr)
    }
}

#endif
extension rtmp {
    enum states {
        static func onStatus(_ level: String,
                             code: String,
                             desc: String,
                             ctx: Context,
                             chunk: Chunk) -> (EventBox<Event>, Context) {
            let result = [amf.Atom("onStatus"),
                          amf.Atom(0),
                          amf.Atom(),
                          netstreamResult(level, code, desc)]
            do {
                let buf = try amf.serialize(result)
                let chunk = chunk.changing(msgLength: buf.readableBytes, data: buf)
                let bytes = serialize.serializeChunk(chunk, ctx: ctx)
                return (bytes.0 <??> { .just(NetworkEvent(time: nil,
                                                          assetId: ctx.assetId,
                                                          workspaceId: ctx.app ?? "",
                                                          workspaceToken: ctx.playPath,
                                                          bytes: $0)) } <|> .nothing(nil),
                        bytes.1)
            } catch (let error) {
                return (.error(EventError("rtmp", -1, "Serialization Error \(error)", assetId: ctx.assetId)), ctx)
            }
        }
        
        static func establish(_ buf: ByteBuffer, ctx: Context) -> (EventBox<Event>, ByteBuffer?, Context, Bool) {
            let (buf, chk, ctx) = deserialize.parseChunk(buf, ctx: ctx)
            if let chunk = chk {
                let (result, ctx) = handleChunk(chunk, ctx: ctx)
                return (result, buf, ctx, ctx.started)
            }
            return (.nothing(nil), buf, ctx, false)
        }
        
        // MARK: - Handshake Functions
        static func c0c1(_ buf: ByteBuffer, ctx: Context) -> (EventBox<Event>, ByteBuffer?, Context, Bool) {
            if let c1 = buffer.getSlice(buf, 1, 1536),
                let res = [buffer.getSlice(buf, 0, 1537), c1].reduce(nil, buffer.concat) {
                // Send S0S1S2
                let evt = NetworkEvent(time: nil,
                                       assetId: ctx.assetId,
                                       workspaceId: ctx.app ?? "",
                                       workspaceToken: ctx.playPath,
                                       bytes: res)
                return (.just(evt), buffer.advancingReader(buf, by: 1537), ctx, true)
            }
            return (.nothing(nil), buf, ctx, false)
        }
        static func writeC0c1( _ ctx: Context ) -> (EventBox<Event>, ByteBuffer?, Context, Bool) {
            
            let bytes: [UInt8] = [0x3, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0]
            var randomBytes = Data(count: 1528)
            _ = randomBytes.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> () in generateRandomBytes(ptr.baseAddress, 1528) }
            guard let outBytes = buffer.concat(buffer.fromData(Data(bytes)), buffer.fromData(randomBytes)) else {
                return (.error(EventError("c0c1", -1)), nil, ctx, false)
            }
            
            let evt = NetworkEvent(time: nil,
                                   assetId: ctx.assetId,
                                   workspaceId: ctx.app ?? "",
                                   workspaceToken: ctx.playPath,
                                   bytes: outBytes)
            return (.just(evt), buffer.advancingReader(evt.data(), by: 1), ctx, true)
        }
        static func s0s1(_ buf: ByteBuffer, ctx: Context) -> (EventBox<Event>, ByteBuffer?, Context, Bool) {
            if let s1 = buffer.getSlice(buf, 1, 1536) {
                // Send C2
                let evt = NetworkEvent(time: nil,
                                       assetId: ctx.assetId,
                                       workspaceId: ctx.app ?? "",
                                       workspaceToken: ctx.playPath, bytes: s1)
                return (.just(evt), buffer.advancingReader(buf, by: 1537), ctx, true)
            }
            return (.nothing(nil), buf, ctx, false)
        }
        static func s2( _ buf: ByteBuffer, ctx: Context) -> (EventBox<Event>, ByteBuffer?, Context, Bool) {
            if let _ = buffer.getSlice(buf, 0, 1536) {
                let buf = buffer.advancingReader(buf, by: 1536)
                let (result, ctx) = createConnect(ctx)
                return (result, buf, ctx, true)
            }
            return (.nothing(nil), buf, ctx, false)
        }
        
        static func c2(_ buf: ByteBuffer, ctx: Context) -> (EventBox<Event>, ByteBuffer?, Context, Bool) {
            if buf.readableBytes >= 1536 {
                return (.nothing(nil), buffer.advancingReader(buf, by: 1536), ctx, true)
            }
            return (.nothing(nil), buf, ctx, false)
        }

        static func unpublish(_ ctx: Context) -> (EventBox<NetworkEvent>, Context) {
            let fcUnpublish = [amf.Atom("FCUnpublish"),
                             amf.Atom(Float64(ctx.commandNumber)),
                             amf.Atom(),
                             amf.Atom(ctx.playPath ?? "")]
            let deleteStream = [amf.Atom("deleteStream"),
                                 amf.Atom(Float64(ctx.commandNumber &+ 1)),
                                 amf.Atom(),
                                 amf.Atom(Float64(ctx.msgStreamId))]
            let makeBuffer: ([amf.Atom], Context) throws -> (ByteBuffer?, Context) = {
                let buf = try amf.serialize($0)
                let chunk = Chunk(msgStreamId: 0,
                                  msgLength: buf.readableBytes,
                                  msgType: 0x14,
                                  chunkStreamId: 3,
                                  timestamp: 0,
                                  timestampDelta: 0,
                                  data: buf)
                return serialize.serializeChunk(chunk, ctx: $1)
            }
            do {
                let commands = [fcUnpublish, deleteStream]
                let res: (ByteBuffer?, Context) = try commands.reduce((nil, ctx)) {
                    (accum: (ByteBuffer?, Context), val: [amf.Atom]) in
                    let res = try makeBuffer(val, accum.1)
                    return (buffer.concat(accum.0, res.0), res.1)
                }
                let responders = ctx.commandResponder?.merging([ctx.commandNumber &+ 2: handleCreateStreamResult]) { $1 }
                return (res.0 <??> {.just(NetworkEvent(time: nil,
                                                       assetId: ctx.assetId,
                                                       workspaceId: ctx.app ?? "",
                                                       workspaceToken: ctx.playPath,
                                                       bytes: $0)) } <|> .nothing(nil),
                        res.1.changing(commandNumber: ctx.commandNumber &+ 2, commandResponder: responders))
            } catch(let error) {
                 return (.error(EventError(ctx.assetId, -1, "Serialization Error \(error)", assetId: ctx.assetId)), ctx)
            }
        }
        
        // MARK: - Handle Messages
        static func handleChunk(_ chunk: Chunk, ctx: Context, clock: Clock? = nil) -> (EventBox<Event>, Context) {
            let chunkHandlers = [0x1: handleChunkSize,
                                 0x4: handleUserControl,
                                 0x8: handleAudio,
                                 0x9: handleVideo,
                                 0x12: handleData,
                                 0x14: handleCommand]
            return chunkHandlers[chunk.msgType] <??> { $0(chunk, ctx, clock) } <|> (.nothing(nil), ctx)
        }
        private static func handleChunkSize(_ chunk: Chunk, ctx: Context, clock: Clock?) -> (EventBox<Event>, Context) {
            guard let data = chunk.data,
                  let bytes = buffer.readBytes(data, length: 4).1 else {
                return (.nothing(nil), ctx)
            }
            let inChunkSize = Int(UnsafeRawPointer(bytes).load(as: Int32.self).byteSwapped)
            return (.nothing(nil), ctx.changing(inChunkSize: inChunkSize))
        }
        private static func handleUserControl(_ chunk: Chunk, ctx: Context, clock: Clock?) -> (EventBox<Event>, Context) {
            return (.nothing(nil), ctx)
        }
        private static func handleVideo(_ chunk: Chunk, ctx: Context, clock: Clock?) -> (EventBox<Event>, Context) {
            let header = chunk.data.map { buffer.readBytes($0, length: 5) } // flags + config + cts (24-bit)
            guard let data = buffer.toDataCopy(header?.0), let bytes = header?.1 else {
                return (.nothing(nil), ctx)
            }
            let isConfig = bytes[1] == 0
            if isConfig && data.count > 4 {
                let sideData = ctx.sideData.merging(["videoConfig": data]) { $1 }
                return (.nothing(nil), ctx.changing(sideData: sideData))
            } else if let sideData = ctx.sideData["videoConfig"], data.count > 0 {
                let cts = Int(bytes[4]) | (Int(bytes[3]) << 8) | (Int(bytes[2]) << 16)
                let sample = CodedMediaSample(ctx.assetId,
                                              ctx.app ?? "",
                                              clock?.current() ?? WallClock().current(),
                                              TimePoint(Int64(chunk.timestamp + cts), 1000),
                                              TimePoint(Int64(chunk.timestamp), 1000),
                                              .video,
                                              .avc,
                                              data,
                                              ["config": sideData],
                                              ctx.encoder,
                                              workspaceToken: ctx.playPath)
                return (.just(sample), ctx)
            }
            return (.nothing(nil), ctx)
        }
        private static func handleAudio(_ chunk: Chunk, ctx: Context, clock: Clock?) -> (EventBox<Event>, Context) {
            let header = chunk.data.map { buffer.readBytes($0, length: 2) }
            guard let data = buffer.toDataCopy(header?.0), let bytes = header?.1 else {
                return (.nothing(nil), ctx)
            }
            let isConfig = bytes[1] == 0
            if isConfig {
                let sideData = ctx.sideData.merging(["audioConfig": data]) { $1 }
                return (.nothing(nil), ctx.changing(sideData: sideData))
            } else if let sideData = ctx.sideData["audioConfig"], data.count > 0 {
                let sample = CodedMediaSample(ctx.assetId,
                                              ctx.app ?? "",
                                              clock?.current() ?? WallClock().current(),
                                              TimePoint(Int64(chunk.timestamp), 1000),
                                              TimePoint(Int64(chunk.timestamp), 1000),
                                              .audio,
                                              .aac,
                                              data,
                                              ["config": sideData],
                                              ctx.encoder,
                                              workspaceToken: ctx.playPath)
                return (.just(sample), ctx)
            }
            return (.nothing(nil), ctx)
        }
        private static func handleData(_ chunk: Chunk, ctx: Context, clock: Clock?) -> (EventBox<Event>, Context) {
            let data = amf.deserialize(chunk.data)
            guard let encoder = data.1[safe: 2]?.dict?["encoder"]?.string else {
                return (.nothing(nil), ctx)
            }
            return (.nothing(nil), ctx.changing(encoder: encoder))
        }
        private static func handleCommand(_ chunk: Chunk, ctx: Context, clock: Clock?) -> (EventBox<Event>, Context) {
            let data = amf.deserialize(chunk.data).1
            guard let command = data[safe: 0]?.string else {
                return (.nothing(nil), ctx)
            }
            let commandHandlers = ["connect": handleConnect,
                                   "releaseStream": genericResult,
                                   "FCPublish": genericResult,
                                   "createStream": handleCreateStream,
                                   "publish": handlePublish,
                                   "_result": handleResult,
                                   "onStatus": handleOnStatus]
            return commandHandlers[command] <??> { $0(data, chunk, ctx) } <|> (.nothing(nil), ctx)
        }
        
        private static func genericResult(_ data: [amf.Atom], chunk: Chunk, ctx: Context) -> (EventBox<Event>, Context) {
            if let ident = data[safe: 1]?.number {
                let result = [amf.Atom("_result"), amf.Atom(ident)]
                do {
                    let buf = try amf.serialize(result)
                    let chunk = chunk.changing(msgLength: buf.readableBytes, data: buf)
                    let bytes = serialize.serializeChunk(chunk, ctx: ctx)
                    return (bytes.0 <??> { .just(NetworkEvent(time: nil,
                                                              assetId: ctx.assetId,
                                                              workspaceId: ctx.app ?? "",
                                                              workspaceToken: ctx.playPath,
                                                              bytes: $0)) } <|> .nothing(nil), bytes.1)
                } catch (let error) {
                    return (.error(EventError("rtmp", -1, "Serialization Error \(error)")), ctx)
                }
            }
            return (.error(EventError("rtmp", 1, "Access Error", assetId: ctx.assetId)), ctx)
        }
        private static func handleCreateStream(_ data: [amf.Atom], chunk: Chunk, ctx: Context) -> (EventBox<Event>, Context) {
            if let ident = data[safe: 1]?.number {
                let msgStreamId = ctx.msgStreamId + 1
                let result = [amf.Atom("_result"), amf.Atom(ident), amf.Atom(), amf.Atom(Float64(msgStreamId))]
                do {
                    let buf = try amf.serialize(result)
                    let chunk = chunk.changing(msgLength: buf.readableBytes, data: buf)
                    let bytes = serialize.serializeChunk(chunk, ctx: ctx.changing(msgStreamId: msgStreamId))
                    return (bytes.0 <??> { .just(NetworkEvent(time: nil,
                                                              assetId: ctx.assetId,
                                                              workspaceId: ctx.app ?? "",
                                                              workspaceToken: ctx.playPath,
                                                              bytes: $0)) } <|> .nothing(nil), bytes.1)
                } catch (let error) {
                    return (.error(EventError(ctx.assetId, -1, "Serialization Error \(error)")), ctx)
                }
            }
            return (.error(EventError("NetStream.Create.Fail", 1, "Access Error", nil)), ctx)
        }
        private static func handleConnect(_ data: [amf.Atom], chunk: Chunk, ctx: Context) -> (EventBox<Event>, Context) {
            let (event, ctx) = createSetChunkSize(ctx, 4096)
            if let ident = data[safe: 1]?.number,
                let obj = data[safe: 2]?.dict,
                let app = obj["app"]?.string,
                let tcUrl = obj["tcUrl"]?.string {
                let result = [amf.Atom("_result"),
                              amf.Atom(ident),
                              amf.Atom(["fmsVer": amf.Atom("FMS/3,0,1,123"),
                                           "capabilities": amf.Atom(31.0)]),
                              netstreamResult("status", "NetConnection.Connect.Success", "Connection succeeded")]
                do {
                    let buf = try amf.serialize(result)
                    let chunk = chunk.changing(msgLength: buf.readableBytes, data: buf)
                    let bytes = serialize.serializeChunk(chunk, ctx: ctx)
                    return (buffer.concat(event.value()?.data(), bytes.0) <??> { .just(NetworkEvent(time: nil,
                                                              assetId: ctx.assetId,
                                                              workspaceId: ctx.app ?? "",
                                                              workspaceToken: ctx.playPath,
                                                              bytes: $0)) } <|> .nothing(nil),
                            bytes.1.changing(app: app, tcUrl: tcUrl))
                } catch (let error) {
                    return (.error(EventError(ctx.assetId, -1, "Serialization Error \(error)")), ctx)
                }
            }
            return (.error(EventError("NetStream.Connection.Fail", 2, "Invalid connect")), ctx)
        }
        
        private static func handlePublish(_ data: [amf.Atom], chunk: Chunk, ctx: Context) -> (EventBox<Event>, Context) {
            guard let playPath = data[safe: 3]?.string else {
                return (.error(EventError("NetStream.Publish.Fail", 1, "No access")), ctx)
            }
            return (.nothing(nil), ctx.changing(playPath: playPath, started: true, publishToPeer: false))
        }
        
        private static func handleOnStatus(_ data: [amf.Atom], chunk: Chunk, ctx: Context) -> (EventBox<Event>, Context) {
            guard let code = data[safe: 3]?.dict?["code"]?.string else {
                return (.nothing(nil), ctx)
            }
            if code == "NetStream.Publish.Start" {
                return (.nothing(nil), ctx.changing(started: true))
            } else if code == "NetStream.Play.Start" {
                return (.nothing(nil), ctx.changing(started: true))
            }
            return (.error(EventError(ctx.assetId, -1, code, nil)), ctx)
        }
        
        private static func netstreamResult(_ level: String, _ code: String, _ desc: String) -> amf.Atom {
            return amf.Atom(["level": amf.Atom(level),
                                "code": amf.Atom(code),
                                "description": amf.Atom(desc),
                                "objectEncoding": amf.Atom(0.0)])
        }
        
        private static func handleResult(_ data: [amf.Atom], chunk: Chunk, ctx: Context) -> (EventBox<Event>, Context) {
            guard let ident = data[safe:1]?.number, let fun = ctx.commandResponder?[Int(ident)] else {
                return (.nothing(nil), ctx)
            }
            let result = fun(data, chunk, ctx)
            let responders = result.1.commandResponder?.filter { $0.key != Int(ident) }
            return (result.0, result.1.changing(commandResponder: responders))
        }
        
        private static func createSetChunkSize(_ ctx: Context, _ size: Int32) -> (EventBox<NetworkEvent>, Context) {
            let chunk = Chunk(msgStreamId: ctx.msgStreamId,
                              msgLength: 4,
                              msgType: 0x1,
                              chunkStreamId: 2,
                              timestamp: 0,
                              timestampDelta: 0,
                              data: buffer.fromData(Data(buffer.toByteArray(size.bigEndian))))
            let result = serialize.serializeChunk(chunk, ctx: ctx)

            return (result.0 <??> { .just(NetworkEvent(time: nil, 
                                                       assetId: ctx.assetId, 
                                                       workspaceId:ctx.app ?? "",
                                                       workspaceToken: ctx.playPath,
                                                       bytes: $0)) } <|> .nothing(nil),
                   result.1.changing(outChunkSize: Int(size)))
        }

        private static func createConnect(_ ctx: Context) -> (EventBox<Event>, Context) {
            let props = amf.Atom(["app": amf.Atom(ctx.app ?? ""), "tcUrl": amf.Atom(ctx.tcUrl ?? "")])
            let atoms = [amf.Atom("connect"), amf.Atom(Float64(ctx.commandNumber)), props]
            do {
                let buf = try amf.serialize(atoms)
                let chunk = Chunk(msgStreamId: ctx.msgStreamId,
                                  msgLength: buf.readableBytes,
                                  msgType: 0x14,
                                  chunkStreamId: 3,
                                  timestamp: 0,
                                  timestampDelta: 0,
                                  data: buf)
                let result = serialize.serializeChunk(chunk, ctx: ctx)
                let responders = result.1.commandResponder?.merging([ctx.commandNumber: handleConnectResult]) { $1 }
                return (result.0 <??> { .just(NetworkEvent(time: nil,
                                                           assetId: ctx.assetId,
                                                           workspaceId: ctx.app ?? "",
                                                           workspaceToken: ctx.playPath,
                                                           bytes: $0)) } <|> .nothing(nil),
                        result.1.changing(commandNumber: result.1.commandNumber &+ 1, commandResponder: responders))
            } catch (let error) {
                return (.error(EventError("rtmp", -1, "Serialization Error \(error)", assetId: ctx.assetId)), ctx)
            }
        }
        
        private static func handleConnectResult(_ data: [amf.Atom], chunk: Chunk, ctx: Context) -> (EventBox<Event>, Context) {
            guard let response = data[safe: 3]?.dict?["code"]?.string, response == "NetConnection.Connect.Success" else {
                return (.error(EventError("NetConnection.Connect.Fail", 1, "Access Error")), ctx)
            }
            return createCreateStream(ctx)
        }
        
        private static func createCreateStream( _ ctx : Context ) -> (EventBox<Event>, Context) {
            let releaseStream = [amf.Atom("releaseStream"),
                                 amf.Atom(Float64(ctx.commandNumber)),
                                 amf.Atom(),
                                 amf.Atom(ctx.playPath ?? "")]
            let fcPublish = [amf.Atom("FCPublish"),
                             amf.Atom(Float64(ctx.commandNumber &+ 1)),
                             amf.Atom(),
                             amf.Atom(ctx.playPath ?? "")]
            let createStream = [amf.Atom("createStream"),
                                 amf.Atom(Float64(ctx.commandNumber &+ 2)),
                                 amf.Atom()]
            let makeBuffer: ([amf.Atom], Context) throws -> (ByteBuffer?, Context) = {
                let buf = try amf.serialize($0)
                let chunk = Chunk(msgStreamId: ctx.msgStreamId,
                                  msgLength: buf.readableBytes,
                                  msgType: 0x14,
                                  chunkStreamId: 3,
                                  timestamp: 0,
                                  timestampDelta: 0,
                                  data: buf)
                return serialize.serializeChunk(chunk, ctx: $1)
            }
            do {
                let commands = [releaseStream, fcPublish, createStream]
                let res: (ByteBuffer?, Context) = try commands.reduce((nil, ctx)) {
                    (accum: (ByteBuffer?, Context), val: [amf.Atom]) in
                    let res = try makeBuffer(val, accum.1)
                    return (buffer.concat(accum.0, res.0), res.1)
                }
                let responders = ctx.commandResponder?.merging([ctx.commandNumber &+ 2: handleCreateStreamResult]) { $1 }
                return (res.0 <??> {.just(NetworkEvent(time: nil,
                                                       assetId: ctx.assetId,
                                                       workspaceId: ctx.app ?? "",
                                                       workspaceToken: ctx.playPath,
                                                       bytes: $0)) } <|> .nothing(nil),
                        res.1.changing(commandNumber: ctx.commandNumber &+ 3, commandResponder: responders))
            } catch(let error) {
                 return (.error(EventError(ctx.assetId, -1, "Serialization Error \(error)", assetId: ctx.assetId)), ctx)
            }
        }
        
        private static func handleCreateStreamResult(_ data: [amf.Atom], chunk: Chunk, ctx: Context) -> (EventBox<Event>, Context) {
            guard let streamId = data[safe: 3]?.number else {
                return (.error(EventError("rtmp", -1, "Invalid create stream result.")), ctx)
            }
            let ctx = ctx.changing(msgStreamId: Int(streamId))
            return ctx.publishToPeer ? createPublish(ctx) : createPlay(ctx)
        }
        private static func createPlay(_ ctx: Context) -> (EventBox<Event>, Context) {
            #warning("TODO: Implement Play")
            return (.error(EventError(ctx.assetId, -99, "Play Not Implemented", nil)), ctx)
        }
        private static func createPublish(_ ctx: Context) -> (EventBox<Event>, Context) {
            
            let data = [amf.Atom("publish"),
                        amf.Atom(Float64(ctx.commandNumber)),
                        amf.Atom(),
                        amf.Atom(ctx.playPath ?? "")]
            do {
                let buf = try amf.serialize(data)
                let chunk = Chunk(msgStreamId: ctx.msgStreamId,
                                  msgLength: buf.readableBytes,
                                  msgType: 0x14,
                                  chunkStreamId: 3,
                                  timestamp: 0,
                                  timestampDelta: 0,
                                  data: buf)
                let result = serialize.serializeChunk(chunk, ctx: ctx)
                return (result.0 <??> {.just(NetworkEvent(time: nil,
                                                          assetId: ctx.assetId,
                                                          workspaceId: ctx.app ?? "",
                                                          workspaceToken: ctx.playPath,
                                                          bytes: $0)) } <|> .nothing(nil),
                        result.1.changing(commandNumber: ctx.commandNumber &+ 1))
            } catch (let error) {
                return (.error(EventError("rtmp", -1, "Serialization Error \(error)", assetId: ctx.assetId)), ctx)
            }
        }
    }
}
