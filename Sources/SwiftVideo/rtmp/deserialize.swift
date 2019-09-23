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

extension rtmp {
    enum deserialize {
        static func parseChunk(_ buf: ByteBuffer, ctx: Context) -> (ByteBuffer?, Chunk?, Context) {
            let cfsid = getChunkHeader(buf)
            if let cfsid = cfsid,
                let pBuf = cfsid.0 {
                    let formatId = cfsid.1
                    let chunkStreamId = cfsid.2
                    let chunkParserMap : [(ByteBuffer?, Int, Chunk?, Context) -> (ByteBuffer?, Chunk?)] = [getChunk0, getChunk1, getChunk2, getChunk3]
                    let result = chunkParserMap[safe: Int(formatId)]?(pBuf, chunkStreamId, ctx.inChunks[Int(chunkStreamId)], ctx)
                    let complete = result?.1 <??> { chunkComplete($0) } <|> false
                    let chunks = result?.1 <??> {
                            return ctx.inChunks.merging([chunkStreamId: complete ? $0.changing(data: nil) : $0 ]) { $1 }
                        } <|> ctx.inChunks
                    return (result?.0 ?? buf, complete ? result?.1 : nil, ctx.changing(inChunks: chunks))
            }
            return (buf, nil, ctx)
        }
        private static func chunkComplete(_ chunk: Chunk?) -> Bool {
            guard let chunk = chunk,
                let buf = chunk.data else {
                    return false
            }
            return buf.readableBytes == chunk.msgLength
        }
        private static func getChunkHeader(_ data: ByteBuffer?) -> (ByteBuffer?, Int, Int)? {
            guard let buf = data else {
                return nil
            }
            let bytes = buffer.readBytes(buf, length: 1)
            if let buf = bytes.0, let bytes = bytes.1 {
                let formatId = Int((bytes[0] & 0xc0) >> 6)
                let streamId = Int(bytes[0] & 0x3f)
                if streamId == 0 {
                    let buf = buffer.readBytes(buf, length: 1)
                    return buf.1 <??> { (buf.0, formatId, Int($0[0]) + 64) } <|> nil
                } else if streamId == 1 {
                    let buf = buffer.readBytes(buf, length: 2)
                    return buf.1 <??> { (buf.0, formatId, Int(UnsafeRawPointer($0).load(as: UInt16.self))) } <|> nil
                } else {
                    return (buf, formatId, streamId)
                }
            } else {
                return nil
            }
        }
        private static func getChunk0(_ data: ByteBuffer?, _ csid : Int, _ prev : Chunk?, _ ctx: Context) -> (ByteBuffer?, Chunk?) {
            let pBuf = data <??> { buffer.readBytes($0, length: 11) } <|> (nil, nil)
            guard let bytes = pBuf.1 else {
                return (nil, nil)
            }
            let (ts, buf) = { () -> (UInt32?, ByteBuffer?) in
                let ts = UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
                if(ts == 0xFFFFFF) {
                    return (pBuf.0?.getInteger(at: 0, endianness: .big, as: UInt32.self), buffer.advancingReader(pBuf.0, by: 4))
                }
                return (ts, pBuf.0)
            }()
            let len = Int(bytes[3]) << 16 | Int(bytes[4]) << 8 | Int(bytes[5])
            guard let serialTimestamp = ts, let slice = buffer.getSlice(buf, min(len, ctx.inChunkSize)) else {
                return (nil, nil)
            }
            // see https://tools.ietf.org/html/rfc1982
            let timestamp = prev.map { 
                let serialTimestamp = Int(serialTimestamp)
                let prevSerial = $0.timestamp % 0xffffffff
                if prevSerial > serialTimestamp && 
                    (prevSerial - serialTimestamp) > 0x7fffffff {
                    return $0.timestamp + serialTimestamp + (0xffffffff - prevSerial)
                } else {
                    return $0.timestamp + (serialTimestamp - prevSerial)
                }  
            } ?? Int(serialTimestamp)
            let chunk = Chunk(msgStreamId: Int(bytes[7]) | (Int(bytes[8]) << 8) | (Int(bytes[9]) << 16) | (Int(bytes[10]) << 24),
                              msgLength: len,
                              msgType: Int(bytes[6]),
                              chunkStreamId: csid,
                              timestamp: timestamp,
                              timestampDelta: 0,
                              extended: serialTimestamp >= 0xffffff,
                              data: slice)
            
            let next = buffer.advancingReader(buf, by: slice.readableBytes)
            return (next, chunk)
        }
        
        private static func getChunk1(_ data: ByteBuffer?, _ csid : Int, _ prev : Chunk?, _ ctx: Context) -> (ByteBuffer?, Chunk?) {
            let pBuf = data <??> { buffer.readBytes($0, length: 7) } <|> (nil, nil)
            guard let bytes = pBuf.1, let prev_ = prev else {
                return (nil, nil)
            }
            let (ts, buf) = { () -> (UInt32?, ByteBuffer?) in
                let ts = UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
                if(ts == 0xFFFFFF) {
                    return (pBuf.0?.getInteger(at: 0, endianness: .big, as: UInt32.self), buffer.advancingReader(pBuf.0, by: 4))
                }
                return (ts, pBuf.0)
            }()
            let len = Int(bytes[3]) << 16 | Int(bytes[4]) << 8 | Int(bytes[5])
            guard let tsDelta = ts, let slice = buffer.getSlice(buf, min(len, ctx.inChunkSize)) else {
                return (nil, nil)
            }
            let timestamp = prev_.timestamp &+ Int(tsDelta)
            let chunk = prev_.changing(msgLength: len,
                                       msgType: Int(bytes[6]),
                                       timestamp: timestamp,
                                       timestampDelta: Int(tsDelta),
                                       extended: tsDelta >= 0xffffff,
                                       data: buffer.concat(prev_.data, slice))
            return (buffer.advancingReader(buf, by: slice.readableBytes), chunk)
        }
        
        private static func getChunk2(_ data: ByteBuffer?, _ csid : Int, _ prev : Chunk?, _ ctx: Context) -> (ByteBuffer?, Chunk?) {
            let pBuf = data <??> { buffer.readBytes($0, length: 3) } <|> (nil, nil)
            guard let bytes = pBuf.1, let prev = prev else {
                return (nil, nil)
            }
            let (ts, buf) = { () -> (UInt32?, ByteBuffer?) in
                let ts = UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
                if(ts == 0xFFFFFF) {
                    return (pBuf.0?.getInteger(at: 0, endianness: .big, as: UInt32.self), buffer.advancingReader(pBuf.0, by: 4))
                }
                return (ts, pBuf.0)
            }()
            guard let tsDelta = ts, let slice = buffer.getSlice(buf, min(prev.msgLength, ctx.inChunkSize)) else {
                return (nil, nil)
            }
            let timestamp = prev.timestamp &+ Int(tsDelta)
            let chunk = prev.changing(timestamp: timestamp,
                                      timestampDelta: Int(tsDelta),
                                      extended: tsDelta >= 0xffffff,
                                      data: buffer.concat(prev.data, slice))
            return (buffer.advancingReader(buf, by: slice.readableBytes), chunk)
        }
        
        private static func getChunk3(_ data: ByteBuffer?, _ csid : Int, _ prevChunk : Chunk?, _ ctx: Context) -> (ByteBuffer?, Chunk?) {
            guard let prev = prevChunk else {
                    return (nil, nil)
            }

            let readableBytes = prev.data?.readableBytes ?? 0
            let buf = prev.extended ? buffer.advancingReader(data, by: 4) : data
            if let slice = buffer.getSlice(buf, min(prev.msgLength - readableBytes, ctx.inChunkSize)) {
                let continuation = readableBytes > 0
                let timestamp = continuation ? prev.timestamp : prev.timestamp &+ prev.timestampDelta
                let chunk = prev.changing(timestamp: timestamp,
                                      data: buffer.concat(prev.data, slice))
                return (buffer.advancingReader(buf, by: slice.readableBytes), chunk)
            } else {
                return (nil, nil)
            }
        }
    }
}
