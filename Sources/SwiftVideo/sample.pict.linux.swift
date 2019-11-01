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

public struct ImageBuffer {
    public init(pixelFormat: PixelFormat,
                bufferType: BufferType,
                size: Vector2,
                computeTextures: [ComputeBuffer] = [ComputeBuffer](),
                buffers: [Data] = [Data](),
                planes: [Plane] = [Plane]()) throws {
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
                bufferType: BufferType? = nil) {
        self.pixelFormat = other.pixelFormat
        self.bufferType = bufferType ?? other.bufferType
        self.size = other.size
        self.buffers = other.buffers
        self.computeTextures = computeTextures
        self.planes = other.planes
    }

    public init(_ other: ImageBuffer,
                buffers: [Data],
                bufferType: BufferType? = nil) {
        self.pixelFormat = other.pixelFormat
        self.bufferType = bufferType ?? other.bufferType
        self.size = other.size
        self.buffers = buffers
        self.computeTextures = other.computeTextures
        self.planes = other.planes
    }

    let pixelFormat: PixelFormat
    let bufferType: BufferType
    let size: Vector2

    let computeTextures: [ComputeBuffer]
    let buffers: [Data]
    let planes: [Plane]
}

extension ImageBuffer {
    // swiftlint:disable identifier_name
    public func withUnsafeMutableRawPointer<T>(forPlane plane: Int,
                                               fn: (UnsafeMutableRawPointer?) throws -> T) rethrows -> T {
        var buffer = self.buffers[safe: plane]
        let result = try buffer?.withUnsafeMutableBytes {
            try fn($0.baseAddress)
        }
        return try result ?? fn(nil)
    }
    // swiftlint:enable identifier_name
}

public final class PictureSample: PictureEvent {
    private let imgBuffer: ImageBuffer?

    public func pts() -> TimePoint {
        return self.presentationTimestamp
    }

    public func matrix() -> Matrix4 {
        return self.transform
    }

    public func textureMatrix() -> Matrix4 {
        return self.texTransform
    }

    public func size() -> Vector2 {
        guard let img = imgBuffer else {
            return Vector2.zero
        }
        return img.size
    }

    public func zIndex() -> Int {
        return Int(round((Vector3(0, 0, 0) * self.transform).z))
    }

    public func pixelFormat() -> PixelFormat {
        guard let img = imageBuffer() else {
            return .invalid
        }
        return img.pixelFormat
    }
    public func bufferType() -> BufferType {
        guard let img = imageBuffer() else {
            return .invalid
        }
        return img.bufferType
    }
    public func lock() {}

    public func unlock() {}

    public func type() -> String {
        return "pict"
    }

    public func time() -> TimePoint {
        return self.timePoint
    }

    public func assetId() -> String {
        return self.idAsset
    }

    public func workspaceId() -> String {
        return self.idWorkspace
    }

    public func workspaceToken() -> String? {
        return self.tokenWorkspace
    }

    public func info() -> EventInfo? {
        return eventInfo
    }

    public func imageBuffer() -> ImageBuffer? {
        return imgBuffer
    }
    public func constituents() -> [MediaConstituent]? {
        return self.mediaConstituents
    }

    public func revision() -> String {
        return idRevision
    }

    public func borderMatrix() -> Matrix4 {
        return borderTransform
    }

    public func fillColor() -> Vector4 {
        return bgColor
    }

    public func opacity() -> Float {
        return alpha
    }

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
func createPictureSample(_ size: Vector2,
                         _ format: PixelFormat,
                         assetId: String,
                         workspaceId: String,
                         workspaceToken: String? = nil) throws -> PictureSample {
    guard size.x > 0 && size.y > 0 else {
        throw ComputeError.invalidOperation
    }
    let width = Int(size.x)
    let height = Int(size.y)
    let (buffers, planes) = try { () -> ([Data], [Plane]) in
            switch format {
            case .nv12:
                return ([Data(count: width*height), Data(count: width*(height/2))],
                        [Plane(size: size, stride: width, bitDepth: 8, components: [.y]),
                         Plane(size: size/2, stride: width, bitDepth: 8, components: [.cb, .cr])])
            case .BGRA, .RGBA:
                return ([Data(count: width*4*height)], [Plane(
                    size: size, stride: width*4, bitDepth: 8, components: [.r, .g, .b, .a])])
            case .yuvs:
                return([Data(count: width*2*height)], [Plane(
                    size: size, stride: width*2, bitDepth: 8, components: [.cr, .y, .cb, .y])])
            case .zvuy:
                return([Data(count: width*2*height)], [Plane(
                    size: size, stride: width*2, bitDepth: 8, components: [.y, .cb, .y, .cr])])
            case .y420p:
                return ([Data(count: width*height),
                         Data(count: (width/2)*(height/2)),
                         Data(count: (width/2)*(height/2))],
                        [Plane(size: size, stride: width, bitDepth: 8, components: [.y]),
                         Plane(size: size/2, stride: width/2, bitDepth: 8, components: [.cb]),
                         Plane(size: size/2, stride: width/2, bitDepth: 8, components: [.cr])])
            default:
                throw ComputeError.badInputData(description: "Invalid pixel format")
            }
        }()

    let img = try ImageBuffer(pixelFormat: format, bufferType: .cpu, size: size, buffers: buffers, planes: planes)

    return PictureSample(img,
                         assetId: assetId,
                         workspaceId: workspaceId,
                         workspaceToken: workspaceToken,
                         time: TimePoint(0),
                         pts: TimePoint(0))
}

#endif
