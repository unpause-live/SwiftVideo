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
import struct Foundation.Data

// swiftlint:disable identifier_name
// swiftlint:disable type_name
public enum buffer {
    // Concatenate ByteBuffers into one buffer.
    // Can be used as a reducer.
    // This will potentially cause unintended side-effects if you use an existing buffer as lhs
    // because it will be resized and appended to.
    // So be aware of ownership and expectations in that case.
    public static func concat(_ lhs: ByteBuffer?, _ rhs: ByteBuffer? = nil) -> ByteBuffer? {
        var res: ByteBuffer?
        if lhs == nil {
            if let rhs = rhs {
                let allocator = ByteBufferAllocator()
                res = allocator.buffer(capacity: rhs.readableBytes)
            }
        } else if let lhs = lhs {
            res = lhs.getSlice(at: lhs.readerIndex, length: lhs.readableBytes)
            if let rhs = rhs, var res = res {
                let needed = max(rhs.readableBytes - res.writableBytes, 0)
                res.reserveCapacity(res.capacity + needed) // mutates
            }
        }
        // Unfortunately no real way to do this in an immutable fashion.
        // The ByteBuffer needs the writer index moved forward to enable
        // bytes to be readable.
        if var res = res, let rhs = rhs {
            res.setBuffer(rhs, at: res.readableBytes)
            res.moveWriterIndex(forwardBy: rhs.readableBytes) // mutates
            return res
        }

        return res
    }

    public static func readBytes(_ buf: ByteBuffer, length: Int) -> (ByteBuffer?, [UInt8]?) {
        // Slice is mutated here and returned as a new ByteBuffer?
        var mutBuf = buf.getSlice(at: buf.readerIndex, length: buf.readableBytes)
        let bytes = mutBuf?.readBytes(length: length)
        return (rebase(mutBuf), bytes)
    }

    public static func getSlice(_ buf: ByteBuffer?, _ at: Int, _ length: Int) -> ByteBuffer? {
        if let buf = buf {
            let total = max(at - buf.readerIndex, 0) &+ length
            if total > 0 && total <= buf.readableBytes && length > 0 {
                return buf.getSlice(at: at, length: length)
            }
        }
        return nil
    }

    public static func getSlice(_ buf: ByteBuffer?, _ length: Int) -> ByteBuffer? {
        if let buf = buf {
            return getSlice(buf, buf.readerIndex, length)
        }
        return nil
    }

    public static func advancingReader(_ buf: ByteBuffer?, by: Int) -> ByteBuffer? {
        if var buf = buf {
            if buf.readableBytes >= by {
                buf.moveReaderIndex(forwardBy: by) // mutates
                return buf//rebase(buf)
            }
        }
        return nil
    }

    public static func rebase(_ buf: ByteBuffer?) -> ByteBuffer? {
        if var buf = buf {
            buf.discardReadBytes()
            return buf
        }
        return buf
    }

    public static func fromUnsafeBytes(_ bytes: UnsafePointer<Int8>?, _ size: Int) -> ByteBuffer {
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: size)
        buf.writeWithUnsafeMutableBytes { (ptr) -> Int in
            guard let dst = ptr.baseAddress, let src = bytes else {
                return 0
            }
            memcpy(dst, src, size)
            return size
        }
        return buf
    }

    public static func fromData(_ data: Data) -> ByteBuffer {
        return data.withUnsafeBytes {
            buffer.fromUnsafeBytes(
                $0.baseAddress.map { $0.bindMemory(to: Int8.self, capacity: data.count) },
                data.count)
        }
    }

    public static func toData(_ buf: ByteBuffer?) -> Data? {
        return buf.flatMap { $0.getData(at: $0.readerIndex, length: $0.readableBytes) }
    }

    public static func toDataCopy( _ buf: ByteBuffer?) -> Data? {
        if let buf = buf {
            return buf.withUnsafeReadableBytes { buf in
                buf.baseAddress <??> { Data(bytes: $0, count: buf.count) } <|> nil
            }
        }
        return nil
    }

    public static func toByteArray<T>(_ value: T) -> [UInt8] where T: FixedWidthInteger {
        var value = value
        return withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<T>.size) {
                Array(UnsafeBufferPointer(start: $0, count: MemoryLayout<T>.size))
            }
        }
    }
}
// swiftlint:enable identifier_name
// swiftlint:enable type_name
