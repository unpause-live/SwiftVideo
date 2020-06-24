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

#if os(Linux)
import VectorMath
import Foundation
import NIO
import struct Foundation.Data

public struct ImageBuffer {
    public init(pixelFormat: PixelFormat,
                bufferType: BufferType,
                size: Vector2,
                computeTextures: [ComputeBuffer] = [ComputeBuffer](),
                buffers: [Data] = [],
                planes: [Plane] = []) throws {
        guard computeTextures.count > 0 || buffers.count > 0 else {
            throw ComputeError.badInputData(description: "Must provide either compute textures or buffers")
        }
        self.pixelFormat = pixelFormat
        self.bufferType = bufferType
        self.size = size
        self.buffers = buffers
        self.computeTextures = computeTextures
        self.planes = planes
    }

    public init(_ other: ImageBuffer,
                computeTextures: [ComputeBuffer],
                buffers: [Data]? = nil,
                bufferType: BufferType? = nil) {
        self.pixelFormat = other.pixelFormat
        self.bufferType = bufferType ?? other.bufferType
        self.size = other.size
        self.buffers = buffers ?? other.buffers
        self.computeTextures = computeTextures
        self.planes = other.planes
    }

    public init(_ other: ImageBuffer,
                computeTextures: [ComputeBuffer]? = nil,
                buffers: [Data],
                bufferType: BufferType? = nil) {
        self.pixelFormat = other.pixelFormat
        self.bufferType = bufferType ?? other.bufferType
        self.size = other.size
        self.buffers = buffers
        self.computeTextures = computeTextures ?? other.computeTextures
        self.planes = other.planes
    }

    public let pixelFormat: PixelFormat
    public let bufferType: BufferType
    public let size: Vector2

    public let computeTextures: [ComputeBuffer]
    public let buffers: [Data]
    public let planes: [Plane]
}

extension ImageBuffer {
    // swiftlint:disable identifier_name
    public func withUnsafeMutableRawPointer<T>(forPlane plane: Int,
                                               fn: (UnsafeMutableRawPointer?) throws -> T) rethrows -> T {
        if var buffer = self.buffers[safe: plane] {
            return try buffer.withUnsafeMutableBytes {
                try fn($0.baseAddress)
            }
        } else {
            return try fn(nil)
        }
    }

    private func unsafePointerForNext<T>(plane: Int,
                                         ptrs: [UnsafeMutableRawPointer?],
                                         fn: ([UnsafeMutableRawPointer?]) throws -> T) rethrows -> T {
        try self.withUnsafeMutableRawPointer(forPlane: plane) {
            if self.planes.count > plane+1 {
                return try unsafePointerForNext(plane: plane+1, ptrs: ptrs + [$0], fn: fn)
            } else {
                return try fn(ptrs + [$0])
            }
        }
    }

    public func withUnsafeMutableRawPointerForAll<T>(fn: ([UnsafeMutableRawPointer?]) throws -> T) rethrows -> T {
        try unsafePointerForNext(plane: 0, ptrs: [], fn: fn)
    }
    // swiftlint:enable identifier_name
}

public final class PictureSample: PictureEvent {
    private let imgBuffer: ImageBuffer?

    public func pts() -> TimePoint { presentationTimestamp }

    public func matrix() -> Matrix4 { transform }

    public func textureMatrix() -> Matrix4 { texTransform }

    public func size() -> Vector2 { imageBuffer()?.size ?? Vector2.zero }

    public func zIndex() -> Int { Int(round((Vector3(0, 0, 0) * self.transform).z)) }

    public func pixelFormat() -> PixelFormat { imageBuffer()?.pixelFormat ?? .invalid }

    public func bufferType() -> BufferType { imageBuffer()?.bufferType ?? .invalid }

    public func lock() {}

    public func unlock() {}

    public func type() -> String { "pict" }

    public func time() -> TimePoint { timePoint }

    public func assetId() -> String { idAsset }

    public func workspaceId() -> String { idWorkspace }

    public func workspaceToken() -> String? { tokenWorkspace }

    public func info() -> EventInfo? { eventInfo }

    public func imageBuffer() -> ImageBuffer? { imgBuffer }

    public func constituents() -> [MediaConstituent]? { mediaConstituents }

    public func revision() -> String { idRevision }

    public func borderMatrix() -> Matrix4 { borderTransform }

    public func fillColor() -> Vector4 { bgColor }

    public func opacity() -> Float { alpha }

    public init(assetId: String,
                workspaceId: String,
                workspaceToken: String? = nil,
                time: TimePoint,
                pts: TimePoint,
                matrix: Matrix4 = Matrix4.identity,
                textureMatrix: Matrix4 = Matrix4.identity,
                borderMatrix: Matrix4? = nil,
                fillColor: Vector4 = Vector4(0, 0, 0, 1),
                opacity: Float = 1.0,
                constituents: [MediaConstituent]? = nil,
                eventInfo: EventInfo? = nil) {
        self.timePoint = time
        self.presentationTimestamp = pts
        self.idAsset = assetId
        self.idWorkspace = workspaceId
        self.tokenWorkspace = workspaceToken
        self.eventInfo = eventInfo
        self.transform = matrix
        self.texTransform = textureMatrix
        self.imgBuffer = nil
        self.mediaConstituents = constituents
        self.idRevision = assetId
        self.borderTransform = borderMatrix ?? matrix
        self.bgColor = fillColor
        self.alpha = opacity
    }

    public init(_ img: ImageBuffer,
                assetId: String,
                workspaceId: String,
                workspaceToken: String? = nil,
                time: TimePoint,
                pts: TimePoint,
                matrix: Matrix4 = Matrix4.identity,
                textureMatrix: Matrix4 = Matrix4.identity,
                borderMatrix: Matrix4? = nil,
                fillColor: Vector4 = Vector4(0, 0, 0, 1),
                opacity: Float = 1.0,
                constituents: [MediaConstituent]? = nil,
                eventInfo: EventInfo? = nil) {
        self.imgBuffer = img
        self.timePoint = time
        self.presentationTimestamp = pts
        self.idAsset = assetId
        self.idWorkspace = workspaceId
        self.tokenWorkspace = workspaceToken
        self.eventInfo = eventInfo
        self.transform = matrix
        self.texTransform = textureMatrix
        self.mediaConstituents = constituents
        self.idRevision = assetId
        self.borderTransform = borderMatrix ?? matrix
        self.bgColor = fillColor
        self.alpha = opacity
    }

    public init(_ other: PictureSample,
                img: ImageBuffer? = nil,
                assetId: String? = nil,
                matrix: Matrix4? = nil,
                textureMatrix: Matrix4? = nil,
                borderMatrix: Matrix4? = nil,
                fillColor: Vector4? = nil,
                opacity: Float? = nil,
                pts: TimePoint? = nil,
                time: TimePoint? = nil,
                revision: String? = nil,
                constituents: [MediaConstituent]? = nil,
                eventInfo: EventInfo? = nil) {
        self.imgBuffer = img ?? other.imgBuffer
        self.eventInfo = eventInfo ?? other.eventInfo
        self.presentationTimestamp = pts ?? other.presentationTimestamp
        self.idAsset = assetId ?? other.idAsset
        self.idWorkspace = other.idWorkspace
        self.tokenWorkspace = other.tokenWorkspace
        self.timePoint = time ?? other.timePoint
        self.transform = matrix ?? other.transform
        self.texTransform = textureMatrix ?? other.texTransform
        self.mediaConstituents = constituents ?? other.mediaConstituents
        self.idRevision = revision ?? other.idRevision
        self.borderTransform = borderMatrix ?? other.borderTransform
        self.bgColor = fillColor ?? other.fillColor()
        self.alpha = opacity ?? other.alpha
    }

    let mediaConstituents: [MediaConstituent]?
    let eventInfo: EventInfo?
    let transform: Matrix4
    let texTransform: Matrix4
    let borderTransform: Matrix4
    let bgColor: Vector4
    let timePoint: TimePoint
    let presentationTimestamp: TimePoint
    let idAsset: String
    let idWorkspace: String
    let tokenWorkspace: String?
    let idRevision: String
    let alpha: Float
}

// Throws ComputeError:
//   - badInputData if it's unable to create the PictureSample
//
public func createPictureSample(_ size: Vector2,
                                _ format: PixelFormat,
                                assetId: String,
                                workspaceId: String,
                                workspaceToken: String? = nil) throws -> PictureSample {
    guard size.x > 0 && size.y > 0 else {
        throw ComputeError.invalidOperation
    }

    let planes = try planesForFormat(format, size: size)
    let buffers = try buffersForPlanes(planes)
    let img = try ImageBuffer(pixelFormat: format, bufferType: .cpu, size: size, buffers: buffers, planes: planes)

    return PictureSample(img,
                         assetId: assetId,
                         workspaceId: workspaceId,
                         workspaceToken: workspaceToken,
                         time: TimePoint(0),
                         pts: TimePoint(0))
}

private func planesForFormat(_ format: PixelFormat, size: Vector2) throws -> [Plane] {
    let width = Int(size.x)
    switch format {
    case .nv12:
        return [Plane(size: size, stride: width, bitDepth: 8, components: [.y]),
                Plane(size: size/2, stride: width, bitDepth: 8, components: [.cb, .cr])]
    case .BGRA, .RGBA:
        return [Plane(size: size, stride: width*4, bitDepth: 8, components: [.r, .g, .b, .a])]
    case .yuvs:
        return [Plane(size: size, stride: width*2, bitDepth: 8, components: [.cr, .y, .cb, .y])]
    case .zvuy:
        return [Plane(size: size, stride: width*2, bitDepth: 8, components: [.y, .cb, .y, .cr])]
    case .y420p:
        return [Plane(size: size, stride: width, bitDepth: 8, components: [.y]),
                Plane(size: size/2, stride: width/2, bitDepth: 8, components: [.cb]),
                Plane(size: size/2, stride: width/2, bitDepth: 8, components: [.cr])]
    default:
        throw ComputeError.badInputData(description: "Invalid pixel format")
    }
}

private func buffersForPlanes(_ planes: [Plane]) throws -> [Data] {
    let totalSize = planes.reduce(0) { $0 + $1.stride * Int($1.size.y) }
    let allocator = ByteBufferAllocator()
    var backing = allocator.buffer(capacity: totalSize)
    backing.moveWriterIndex(forwardBy: totalSize)
    let offsets = planes.reduce([0]) {
        $0 + [($0.last ?? 0) + ($1.stride * Int($1.size.y))]
    }.prefix(3)
    return try zip(planes, offsets).map { (plane, offset) in
        guard let result = backing.getData(at: offset,
                    length: plane.stride * Int(plane.size.y), byteTransferStrategy: .noCopy) else {
            throw ComputeError.badInputData(description: "Invalid pixel format")
        }
        return result
    }
}
#endif
