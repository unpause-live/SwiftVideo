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

public enum amf {
    public enum Amf0Type : UInt8
    {
        case number = 0
        case bool   = 0x1
        case string = 0x2
        case object = 0x3
        case null   = 0x5
        case assocArray = 0x8
        case objEnd = 0x9
        case strictArray = 0xA
        case date   = 0xB
        case longString = 0xC
        case xml    = 0xF
        case typedObj   = 0x10
        case switchAmf3 = 0x11   // Switch to AMF 3
    }
    
    public struct Atom {
        public init<T>(type: Amf0Type, value: T) {
            self.type = type
            self.dict = value as? [String: Atom]
            self.string = value as? String
            self.number = value as? Float64
            self.bool = value as? Bool
            self.array = value as? [Atom]
        }
        public init(_ value: String) {
            self.init(type: .string, value: value)
        }
        public init(_ value: [String: Atom]) {
            self.init(type: .object, value: value)
        }
        public init(_ value: Float64) {
            self.init(type: .number, value: value)
        }
        public init(_ value: Bool) {
            self.init(type: .bool, value: value)
        }
        public init(_ value: [Atom]) {
            self.init(type: .strictArray, value: value)
        }
        
        public init() {
            type = .null
            self.dict = nil
            self.string = nil
            self.number = nil
            self.bool = nil
            self.array = nil
        }
        let type : Amf0Type
        let dict: [String: Atom]?
        let array: [Atom]?
        let string: String?
        let number: Float64?
        let bool: Bool?
        
    }
    public static func deserialize(_ buf: ByteBuffer?) -> (ByteBuffer?, [Atom]) {
        let current = detail.parse(buf)
        guard let cur = current.1 else {
            return (current.0, [Atom]())
        }
        let next = deserialize(current.0)
        return (next.0, [cur] + next.1)
    }
    
    public static func serialize(_ val: [Atom]) throws -> ByteBuffer {
        let result = try val.reduce(nil) {
            try detail.write($1, buf: $0)
        }
        guard let res = result else {
            throw AmfError.unknownError
        }
        return res
    }
    public enum AmfError : Error {
        case invalidType
        case unsupportedType(Amf0Type)
        case unknownError
    }
    fileprivate enum detail {
        // MARK: - Write Functions
        static func write(_ atom: Atom, buf: ByteBuffer?) throws -> ByteBuffer {
            let result = try { () -> ByteBuffer? in
                switch(atom.type) {
                case .string, .longString:
                    return atom.string.map { writeString($0) }
                case .bool:
                    return atom.bool.map { writeBool($0) }
                case .null:
                    return writeNull()
                case .strictArray:
                    return try atom.array.map { try writeArray($0) }
                case .object:
                    return try atom.dict.map { try writeObj($0) }
                case .assocArray:
                    return try atom.dict.map { try writeAssocArray($0) }
                case .number:
                    return atom.number.map { writeNumber($0) }
                default:
                    return nil
                }
            }()
            guard let r = buffer.concat(buf, result) else {
                throw AmfError.unsupportedType(atom.type)
            }
            return r
        }
        
        static func writeString(_ val: String) -> ByteBuffer {
            if val.count < 0xFFFF {
                let size : UInt16 = UInt16(val.count).byteSwapped
                let bytes : [UInt8] = [Amf0Type.string.rawValue] + buffer.toByteArray(size) + val.utf8
                return buffer.fromData(Data(bytes))
            } else {
                let size : UInt32 = UInt32(val.count & Int(UInt32.max)).byteSwapped
                let bytes : [UInt8] = [Amf0Type.longString.rawValue] + buffer.toByteArray(size) + val.utf8
                return buffer.fromData(Data(bytes))
            }
        }
        
        static func writeNumber(_ val: Float64) -> ByteBuffer {
            let bytes : [UInt8] = [Amf0Type.number.rawValue] + buffer.toByteArray(val.bitPattern.byteSwapped)
            return buffer.fromData(Data(bytes))
        }
        
        static func writeBool(_ val: Bool) -> ByteBuffer {
            let bytes : [UInt8] = [Amf0Type.bool.rawValue] + [UInt8(val ? 1 : 0)]
            return buffer.fromData(Data(bytes))
        }
        
        static func writeNull() -> ByteBuffer {
            let bytes : [UInt8] = [Amf0Type.null.rawValue]
            return buffer.fromData(Data(bytes))
        }
        
        static func writeArray(_ val: [Atom]) throws -> ByteBuffer {
            let bytes = [Amf0Type.strictArray.rawValue] + buffer.toByteArray(UInt32(val.count).byteSwapped)
            let result = try val.reduce(buffer.fromData(Data(bytes))) {
                try write($1, buf: $0)
            }
            return result
        }
        static func writeAssocArray(_ val: [String:Atom]) throws -> ByteBuffer {
            let bytes = [Amf0Type.assocArray.rawValue] + buffer.toByteArray(UInt32(val.count).byteSwapped)
            return try writeObjImpl(val, bytes: bytes)
        }
        static func writeObj(_ val: [String:Atom]) throws -> ByteBuffer {
            let bytes = [Amf0Type.object.rawValue]
            return try writeObjImpl(val, bytes: bytes)
        }
        static func writeObjImpl(_ val: [String:Atom], bytes: [UInt8]) throws -> ByteBuffer {
            let result = try val.reduce(buffer.fromData(Data(bytes))) {
                let size : UInt16 = UInt16($1.0.count).byteSwapped
                let bytes : [UInt8] = buffer.toByteArray(size) + $1.0.utf8
                let buf = buffer.concat($0, buffer.fromData(Data(bytes)))
                return try write($1.1, buf: buf)
            }
            let res = buffer.concat(result, buffer.fromData(Data(buffer.toByteArray(UInt16(0)) + [Amf0Type.objEnd.rawValue])))
            if let res = res {
                return res
            } else {
                throw AmfError.unknownError
            }
        }
        // MARK: - Read Functions
        static func parse(_ buf: ByteBuffer?) -> (ByteBuffer?, Atom?) {
            let (buf, type) = detail.getType(buf)
            return type <??> {
                (type) in
                switch(type) {
                case .number:
                    return detail.readNumber(buf)
                case .string, .longString:
                    return detail.readString(buf, isLong: type == .longString)
                case .bool:
                    return detail.readBool(buf)
                case .object:
                    return detail.readObject(buf)
                case .assocArray:
                    return detail.readAssocArray(buf)
                case .strictArray:
                    return detail.readStrictArray(buf)
                case .null:
                    return (buf, Atom())
                default:
                    return (buf, nil)
                }
                } <|> (buf, nil)
        }
        
        static func getType(_ buf: ByteBuffer?) -> (ByteBuffer?, Amf0Type?) {
            let data = buf.map { buffer.readBytes($0, length: 1) }
            guard let type = data?.1 else {
                return (buf, nil)
            }
            return (data?.0, type.first <??> { Amf0Type(rawValue: $0) } <|> nil )
        }
        
        static func readObject(_ buf: ByteBuffer?) -> (ByteBuffer?, Atom?) {
            let result = readObjectImpl(buf, [String:Atom]())
            return (result.0, Atom(result.1))
        }
        
        static func readObjectImpl(_ buf: ByteBuffer?, _ result: [String:Atom]) -> (ByteBuffer?, [String:Atom]) {
            let (buf, maybeName) = readString(buf)
            guard let name = maybeName?.string else {
                return (buf, result)
            }
            if name.count == 0 {
                let (buf, _) = getType(buf)
                return (buf, result)
            } else {
                let (buf, value) = parse(buf)
                return readObjectImpl(buf, value <??> { [name:$0].merging(result) { _, s in s }} <|> result)
            }
        }
        
        static func readAssocArray(_ buf: ByteBuffer?) -> (ByteBuffer?, Atom?) {
            let (buf, size) = (buf <??> { buffer.readBytes($0, length: MemoryLayout<Int32>.size) } <|> (buf, nil))
            guard size != nil else {
                return (buf, nil)
            }
            return readObject(buf)
        }
        
        static func readStrictArray(_ buf: ByteBuffer?) -> (ByteBuffer?, Atom?) {
            let (pBuf, size): (ByteBuffer?, UInt32?) = readInt(buf)
            guard let sz = size else {
                return (buf, nil)
            }
            let result = readStrictArrayImpl(pBuf, Int(sz), [Atom]())
            return (result.0, Atom(result.1))
        }
        
        static func readStrictArrayImpl(_ buf: ByteBuffer?, _ count: Int, _ result: [Atom]) -> (ByteBuffer?, [Atom]) {
            let (buf, value) = parse(buf)
            if (count - 1) == 0 {
                return (buf, value <??> { result + [$0] } <|> result)
            } else {
                return readStrictArrayImpl(buf, count - 1, value <??> { result + [$0] } <|> result)
            }
        }
        
        static func readNumber(_ buf: ByteBuffer?) -> (ByteBuffer?, Atom?) {
            let data = buf.map { buffer.readBytes($0, length: MemoryLayout<Float64>.size) }
            guard let bytes = data?.1 else {
                return (data?.0, nil)
            }
            let u64 = UnsafeRawPointer(bytes).load(as: UInt64.self).byteSwapped
            let f64 = Float64(bitPattern: u64)
            return (data?.0, Atom(f64))
        }
        
        static func readString(_ buf: ByteBuffer?, isLong: Bool = false) -> (ByteBuffer?, Atom?) {
            if isLong {
                let (pBuf, len) = readInt(buf, as: UInt32.self)
                return len <??> { readString(pBuf, length: $0) } <|> (pBuf, nil)
            } else {
                let (pBuf, len) = readInt(buf, as: UInt16.self)
                return len <??> { readString(pBuf, length: $0) } <|> (pBuf, nil)
            }
        }
        
        static func readString<T>(_ buf: ByteBuffer?, length: T) -> (ByteBuffer?, Atom?) where T: FixedWidthInteger {
            let data = buf.map { buffer.readBytes($0, length: Int(length)) }
            guard let bytes = data?.1 else {
                return (data?.0, nil)
            }
            return (data?.0, String(bytes: bytes, encoding: .utf8) <??> { Atom($0) } <|> nil)
        }
        
        static func readInt<T>(_ buf: ByteBuffer?, as: T.Type = T.self) -> (ByteBuffer?, T?) where T: FixedWidthInteger {
            let data = buf.map { buffer.readBytes($0, length: MemoryLayout<T>.size) }
            guard let bytes = data?.1 else {
                return (data?.0, nil)
            }
            return (data?.0, UnsafeRawPointer(bytes).load(as: T.self).byteSwapped)
        }
        
        static func readBool(_ buf: ByteBuffer?) -> (ByteBuffer?, Atom?) {
            let data = buf.map { buffer.readBytes($0, length: 1) }
            guard let bytes = data?.1 else {
                return (data?.0, nil)
            }
            return (data?.0, bytes.first.map { Atom($0 == 1) })
        }
    }
}
