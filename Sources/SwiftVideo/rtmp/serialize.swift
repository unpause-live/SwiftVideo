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
    enum serialize {

        static func serializeMedia(_ sample: CodedMediaSample, ctx: Context, sendConfig: Bool = false) -> (ByteBuffer?, Context) {
            guard sample.mediaType() == .video || sample.mediaType() == .audio else {
                return (nil, ctx)
            }
            let pts = Int(rescale(sample.pts(), 1000).value)
            let dts = Int(rescale(sample.dts(), 1000).value)
            let cts = pts - dts
            let csId = sample.mediaType() == .video ? 0x6 : 0x4
            let header = { () -> [UInt8] in
                if sample.mediaType() == .video {
                    let frameType: UInt8 =  isKeyframe(sample) ? 0x10 : 0x20
                    return [UInt8(0x7 | frameType), sendConfig ? 0 : 1] + be24(Int32(cts))
                } else {
                    return [0xa0 | 0xc | 0x2 | 0x1, sendConfig ? 0 : 1]
                }
            }()
            let payload = !sendConfig ? buffer.fromData(sample.data()) : sample.sideData()["config"].map { buffer.fromData($0) }
            let buf = buffer.concat(buffer.fromData(Data(header)), payload)
            let chunk = Chunk(msgStreamId: ctx.msgStreamId,
                              msgLength: buf?.readableBytes ?? 0,
                              msgType: sample.mediaType() == .video ? 0x9 : 0x8,
                              chunkStreamId: csId,
                              timestamp: dts,
                              timestampDelta: ctx.outChunks[csId]?.timestamp <??> { dts - $0 } <|> 0,
                              extended: ctx.outChunks[csId]?.extended ?? false,
                              data: buf)
            let result = serializeChunk(chunk, ctx: ctx)
            return result
        }

        static func createMetadata(_ mediaDescription: [BasicMediaDescription], ctx: Context) throws -> (ByteBuffer?, Context) {
            let header = ["encoder": amf.Atom("Cezium 1.0"), "duration": amf.Atom(0.0), "filesize": amf.Atom(0.0)]
            let body: [[String: amf.Atom]] = mediaDescription.map {
                switch $0 {
                    case .video(let desc):
                        return ["width": amf.Atom(Float64(desc.size.x)),
                                "height": amf.Atom(Float64(desc.size.y)),
                                "videodatarate": amf.Atom(1000.0),
                                "framerate": amf.Atom(30.0),
                                "videocodecid": amf.Atom("avc1")]
                    case .audio(let desc):
                        return ["audiodatarate": amf.Atom(96.0),
                                "audiosamplerate": amf.Atom(Float64(desc.sampleRate)),
                                "audiosamplesize": amf.Atom(16.0),
                                "audiochannels": amf.Atom(Float64(desc.channelCount)),
                                "stereo": amf.Atom(desc.channelCount > 1 ? 1.0 : 0.0),
                                "audiocodecid": amf.Atom("mp4a")]
                }
            }
            let props = body.reduce(header) {
                $0.merging($1) { $1 }
            }
            let metadata = try amf.serialize([amf.Atom("@setDataFrame"), amf.Atom("onMetaData"), amf.Atom(props)])
            let chunk = Chunk(msgStreamId: ctx.msgStreamId,
                              msgLength: metadata.readableBytes,
                              msgType: 0x12, // data
                              chunkStreamId: 0x6,
                              timestamp: 0,
                              timestampDelta: 0,
                              data: metadata)
            let result = serializeChunk(chunk, ctx: ctx)
            return result
        }

        static func serializeChunk(_ chunk: Chunk, ctx: Context) -> (ByteBuffer?, Context) {
            let prev = ctx.outChunks[chunk.chunkStreamId]
            let serialCurrent = chunk.timestamp % 0xffffffff
            let serialPrev = prev.map { $0.timestamp % 0xffffffff }
            let rollover = serialPrev.map { $0 > serialCurrent && ($0 - serialCurrent) > 0x7fffffff } ?? false
            if let prev = prev,
               let lastChunk0 = ctx.lastChunk0[chunk.chunkStreamId],
                rollover == false,
                chunk.timestamp < (lastChunk0 + 2000),
                chunk.timestamp > prev.timestamp && // if timestamps move backwards we must do a chunk 0
                chunk.timestamp - prev.timestamp < 0x7fffffff && // if we have a delta > 24 days must do chunk 0
                prev.msgStreamId == chunk.msgStreamId && // if the message stream has changed we must do a chunk 0
                chunk.chunkStreamId != 3 {

                // decide on type 3
                if chunk.msgLength == prev.msgLength &&
                    chunk.msgType == prev.msgType &&
                    chunk.timestampDelta == prev.timestampDelta &&
                    chunk.timestampDelta > 0 &&
                    chunk.msgLength < ctx.outChunkSize {
                    // Type 3
                    return serializeChunk3(chunk, ctx)
                } else if chunk.msgLength != prev.msgLength || chunk.msgType != prev.msgType || prev.timestampDelta == 0 {
                    // Type 1
                    return serializeChunk1(chunk, ctx)
                } else if prev.timestampDelta != chunk.timestampDelta {
                    // Type 2
                    return serializeChunk2(chunk, ctx)
                } else {
                    // Type 0
                    return serializeChunk0(chunk, ctx)
                }
            } else {
                // Type 0
                return serializeChunk0(chunk, ctx)
            }
        }

        private static func createChunkHeader(_ chunkStreamId: Int, _ chunkFormat: Int) -> [UInt8] {
            if chunkStreamId < 64 {
                return [UInt8(chunkStreamId & 0x3f) | UInt8((chunkFormat & 0x3) << 6)]
            } else if chunkStreamId < (256 + 64) {
                return [UInt8((chunkFormat & 0x3) << 6), UInt8(chunkStreamId - 64)]
            } else {
                return [UInt8((chunkFormat & 0x3) << 6) | UInt8(1)] + buffer.toByteArray(UInt16(chunkStreamId & 0xffff))
            }
        }

        private static func be24(_ val: UInt32) -> [UInt8] {
            return [UInt8((val >> 16) & 0xff), UInt8((val >> 8) & 0xff), UInt8(val & 0xff)]
        }

        private static func be24(_ val: Int32) -> [UInt8] {
            return [UInt8((val >> 16) & 0xff), UInt8((val >> 8) & 0xff), UInt8(val & 0xff)]
        }

        private static func chunkBuffer(_ buf: ByteBuffer?,
            ctx: Context,
            chunkStreamId: Int,
            headerBytes: [UInt8],
            timestamp: UInt32,
            useExtended: Bool) -> ByteBuffer? {
            guard var buf = buf else {
                return nil
            }
            let iterations = buf.readableBytes / ctx.outChunkSize
            let tsBytes: [UInt8] = useExtended ? buffer.toByteArray(timestamp.byteSwapped) : []
            let header = createChunkHeader(chunkStreamId, 3) + tsBytes
            let total = headerBytes.count + buf.readableBytes + header.count * iterations
            let allocator = ByteBufferAllocator()
            var outp = allocator.buffer(capacity: total)
            outp.writeBytes(headerBytes)
            repeat {
                let size = min(ctx.outChunkSize, buf.readableBytes)
                guard var slice = buf.getSlice(at: buf.readerIndex, length: size) else {
                    break
                }
                _ = outp.writeBuffer(&slice)
                if buf.readableBytes > ctx.outChunkSize {
                    _ = outp.writeBytes(header)
                }
                buf.moveReaderIndex(forwardBy: size)
            } while(buf.readableBytes > 0)
            return outp
        }

        private static func serializeChunk0(_ chunk: Chunk, _ ctx: Context) -> (ByteBuffer?, Context) {
            let chunkHeader = createChunkHeader(chunk.chunkStreamId, 0)
            let timestamp: UInt32 = UInt32(max(chunk.timestamp, 0) % 0xffffffff)
            let tsBytes = be24(min(timestamp, 0xffffff))
            let len = be24(Int32(chunk.msgLength))
            let msgType = [UInt8(chunk.msgType & 0xff)]
            let msgStreamId = buffer.toByteArray(UInt32(chunk.msgStreamId))
            let extTsBytes: [UInt8] = timestamp >= 0xffffff ? buffer.toByteArray(timestamp.byteSwapped) : []
            let bytes = chunkHeader + tsBytes + len + msgType + msgStreamId + extTsBytes
            let serializedChunk = chunkBuffer(chunk.data,
                ctx: ctx,
                chunkStreamId: chunk.chunkStreamId,
                headerBytes: bytes,
                timestamp: timestamp,
                useExtended: timestamp >= 0xffffff)
            return (serializedChunk,
                    ctx.changing(
                        outChunks: ctx.outChunks.merging([chunk.chunkStreamId: chunk.changing(timestampDelta: 0,
                            extended: timestamp >= 0xffffff, data: nil)]) { $1 },
                        lastChunk0: ctx.lastChunk0.merging([chunk.chunkStreamId: chunk.timestamp]) { $1 }))
        }

        private static func serializeChunk1(_ chunk: Chunk, _ ctx: Context) -> (ByteBuffer?, Context) {
            let chunkHeader = createChunkHeader(chunk.chunkStreamId, 1)
            let timestampDelta = UInt32(max(chunk.timestampDelta, 0) % 0xffffffff)
            let tsDeltaBytes = be24(min(timestampDelta, 0xffffff))
            let len = be24(Int32(chunk.msgLength))
            let msgType = [UInt8(chunk.msgType & 0xff)]
            let extTsBytes: [UInt8] = timestampDelta >= 0xffffff ? buffer.toByteArray(timestampDelta.byteSwapped) : []
            let bytes = chunkHeader + tsDeltaBytes + len + msgType + extTsBytes
            let serializedChunk = chunkBuffer(chunk.data,
                ctx: ctx,
                chunkStreamId: chunk.chunkStreamId,
                headerBytes: bytes,
                timestamp: UInt32(max(chunk.timestamp, 0) % 0xffffffff),
                useExtended: timestampDelta >= 0xffffff)
            return (serializedChunk,
                    ctx.changing(outChunks: ctx.outChunks.merging([chunk.chunkStreamId: chunk.changing(extended: timestampDelta >= 0xffffff, data: nil)]) { $1 }))
        }

        private static func serializeChunk2(_ chunk: Chunk, _ ctx: Context) -> (ByteBuffer?, Context) {
            let chunkHeader = createChunkHeader(chunk.chunkStreamId, 2)
            let timestampDelta = UInt32(max(chunk.timestampDelta, 0) % 0xffffffff)
            let tsDeltaBytes = be24(min(timestampDelta, 0xffffff))
            let extTsBytes: [UInt8] = timestampDelta >= 0xffffff ? buffer.toByteArray(timestampDelta.byteSwapped) : []
            let bytes = chunkHeader + tsDeltaBytes + extTsBytes
            let serializedChunk = chunkBuffer(chunk.data,
                ctx: ctx,
                chunkStreamId: chunk.chunkStreamId,
                headerBytes: bytes,
                timestamp: UInt32(max(chunk.timestamp, 0) % 0xffffffff),
                useExtended: timestampDelta >= 0xffffff)
            return (serializedChunk,
                    ctx.changing(outChunks: ctx.outChunks.merging([chunk.chunkStreamId: chunk.changing(extended: timestampDelta >= 0xffffff, data: nil)]) { $1 }))
        }

        private static func serializeChunk3(_ chunk: Chunk, _ ctx: Context) -> (ByteBuffer?, Context) {
            let timestamp = UInt32(max(chunk.timestamp, 0) % 0xffffffff)
            let extTsBytes: [UInt8] = chunk.extended ? buffer.toByteArray(timestamp.byteSwapped) : []
            let bytes = createChunkHeader(chunk.chunkStreamId, 3) + extTsBytes
            let serializedChunk = chunkBuffer(chunk.data,
                ctx: ctx,
                chunkStreamId: chunk.chunkStreamId,
                headerBytes: bytes,
                timestamp: UInt32(max(chunk.timestamp, 0) % 0xffffffff),
                useExtended: chunk.extended)
            return (serializedChunk,
                    ctx.changing(outChunks: ctx.outChunks.merging([chunk.chunkStreamId: chunk]) { $1 }))
        }
    }
}
