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

#if os(iOS) || os(macOS) || os(tvOS)
import CoreMedia
import VectorMath

public struct ImageBuffer {
    public init(_ pixelBuffer: CVPixelBuffer,
                computeTextures: [ComputeBuffer]? = nil) {
        self.pixelBuffer = pixelBuffer
        self.computeTextures = computeTextures ?? [ComputeBuffer]()
        let pixelFormat = fromCVPixelFormat(pixelBuffer)
        if CVPixelBufferIsPlanar(pixelBuffer) {
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)

            self.planes = ((0..<planeCount) as CountableRange).map { idx in
                let size = Vector2(Float(CVPixelBufferGetWidthOfPlane(pixelBuffer, idx)),
                                   Float(CVPixelBufferGetHeightOfPlane(pixelBuffer, idx)))
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, idx)
                return  Plane(size: size, stride: stride, bitDepth: 8, components: componentsForPlane(pixelFormat, idx))
            }
        } else {
            let size = Vector2(Float(CVPixelBufferGetWidth(pixelBuffer)), Float(CVPixelBufferGetHeight(pixelBuffer)))
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            self.planes = [Plane(size: size,
                                 stride: stride,
                                 bitDepth: 8,
                                 components: componentsForPlane(pixelFormat, 0))]
        }
    }

   public init(pixelFormat: PixelFormat,
               bufferType: BufferType,
               size: Vector2,
               computeTextures: [ComputeBuffer] = [ComputeBuffer](),
               buffers: [Data] = [Data](),
               planes: [Plane] = [Plane]()) throws {
        let sample = try createPictureSample(size, pixelFormat, assetId: "", workspaceId: "")
        guard let pixelBuffer = sample.imageBuffer()?.pixelBuffer else {
            throw ComputeError.badInputData(description: "Unable to create CVPixelBuffer")
        }
        sample.lock()
        defer {
            sample.unlock()
        }
        if CVPixelBufferIsPlanar(pixelBuffer) {
            buffers.enumerated().forEach { (idx, buffer) in
                let ptr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, idx)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, idx)
                let inStride = planes[safe: idx]?.stride ?? 0
                if stride == inStride || inStride == 0 {
                    let count = stride * CVPixelBufferGetHeightOfPlane(pixelBuffer, idx)
                    var data = buffer
                    data.withUnsafeMutableBytes {
                        $0.baseAddress.map { ptr?.copyMemory(from: $0, byteCount: count) }
                    }
                } else {
                    // copy line by line
                    let ptr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, idx)
                    if let ptr = ptr {
                        var data = buffer
                        data.withUnsafeMutableBytes {
                            guard let baseAddress = $0.baseAddress else {
                                return
                            }
                            for i in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, idx) {
                                let offset = inStride * i
                                let toCopy = min(inStride, stride)
                                (ptr + (stride * i)).copyMemory(from: (baseAddress+offset), byteCount: toCopy)
                            }
                        }
                    } else {
                        print("no pointer???")
                    }
                }
            }
        } else if let buffer = buffers[safe: 0] {
            let ptr = CVPixelBufferGetBaseAddress(pixelBuffer)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let inStride = planes[safe: 0]?.stride ?? 0
            if stride == inStride || inStride == 0 {
                let count = stride * CVPixelBufferGetHeight(pixelBuffer)
                var data = buffer
                data.withUnsafeMutableBytes {
                    $0.baseAddress.map { ptr?.copyMemory(from: $0, byteCount: count) }
                }
            } else {
                // copy line by line
                let ptr = CVPixelBufferGetBaseAddress(pixelBuffer)
                if let ptr = ptr {
                    var data = buffer
                    data.withUnsafeMutableBytes {
                        guard let baseAddress = $0.baseAddress else {
                            return
                        }
                        for idx in 0..<CVPixelBufferGetHeight(pixelBuffer) {
                            let offset = inStride * idx
                            let toCopy = min(inStride, stride)
                            (ptr + (stride * idx)).copyMemory(from: (baseAddress+offset), byteCount: toCopy)
                        }
                    }
                }
            }
        }

        self.init(pixelBuffer, computeTextures: computeTextures)
    }

    public init(_ other: ImageBuffer,
                computeTextures: [ComputeBuffer]? = nil) {
        self.pixelBuffer = other.pixelBuffer
        self.computeTextures = computeTextures ?? other.computeTextures
        self.planes = other.planes
    }

    let computeTextures: [ComputeBuffer]
    public let pixelBuffer: CVPixelBuffer
    let planes: [Plane]
}

extension ImageBuffer {
    // swiftlint:disable identifier_name
    public func withUnsafeMutableRawPointer<T>(forPlane plane: Int,
                                               fn: (UnsafeMutableRawPointer?) throws -> T) rethrows -> T {
        let ptr = CVPixelBufferIsPlanar(self.pixelBuffer) ?
                        CVPixelBufferGetBaseAddressOfPlane(self.pixelBuffer, plane) :
                        CVPixelBufferGetBaseAddress(self.pixelBuffer)
        return try fn(ptr)
    }
    // swiftlint:enable identifier_name
}

public final class PictureSample: PictureEvent {

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
        guard let img = imgBuffer?.pixelBuffer else {
            return Vector2.zero
        }
        return Vector2(Float(CVPixelBufferGetWidth(img)), Float(CVPixelBufferGetHeight(img)))
    }

    public func zIndex() -> Int {
        return Int(round((Vector3(0, 0, 0) * self.transform).z))
    }

    public func pixelFormat() -> PixelFormat {
        guard let img = imgBuffer?.pixelBuffer else {
            return .invalid
        }
        return fromCVPixelFormat(img)
    }

    public func bufferType() -> BufferType {
        return .shared
    }

    public func lock() {
        guard let img = imgBuffer?.pixelBuffer else {
            return
        }
        CVPixelBufferLockBaseAddress(img, .init(rawValue: 0))
    }

    public func unlock() {
        guard let img = imgBuffer?.pixelBuffer else {
            return
        }
        CVPixelBufferUnlockBaseAddress(img, .init(rawValue: 0))
    }

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

    public init(_ buf: CMSampleBuffer,
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
        self.imgBuffer = CMSampleBufferGetImageBuffer(buf).map { ImageBuffer($0) }
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
        self.bgColor = fillColor
        self.borderTransform = borderMatrix ?? matrix
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
        self.bgColor = fillColor
        self.borderTransform = borderMatrix ?? matrix
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
        self.bgColor = fillColor ?? other.bgColor
        self.alpha = opacity ?? other.alpha
    }

    let mediaConstituents: [MediaConstituent]?
    let imgBuffer: ImageBuffer?
    let eventInfo: EventInfo?
    let transform: Matrix4
    let texTransform: Matrix4
    let borderTransform: Matrix4
    let bgColor: Vector4
    let alpha: Float
    let timePoint: TimePoint
    let presentationTimestamp: TimePoint
    let idAsset: String
    let idWorkspace: String
    let tokenWorkspace: String?
    let idRevision: String
}

// Create a PictureSample for the Apple platform backed by an IOSurface
// Throws ComputeError:
//   - badInputData if it's unable to create the CVPixelBuffer
//
func createPictureSample(_ size: Vector2,
                         _ format: PixelFormat,
                         assetId: String,
                         workspaceId: String,
                         workspaceToken: String? = nil) throws -> PictureSample {
    guard size.x > 0 && size.y > 0 else {
        throw ComputeError.invalidOperation
    }

    let pixelFormat = try toCVPixelFormat(format)

    let options: CFDictionary = {
        if #available(iOS 9.0, macOS 10.11, tvOS 10.2, *) {
            return [
                  kCVPixelBufferMetalCompatibilityKey: true as CFBoolean,
                  kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                  kCVPixelBufferWidthKey: size.x as CFNumber,
                  kCVPixelBufferHeightKey: size.y as CFNumber,
                  kCVPixelBufferPixelFormatTypeKey: pixelFormat as CFNumber
            ] as CFDictionary
        } else {
            return [
                  kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                  kCVPixelBufferWidthKey: size.x as CFNumber,
                  kCVPixelBufferHeightKey: size.y as CFNumber,
                  kCVPixelBufferPixelFormatTypeKey: pixelFormat as CFNumber
            ] as CFDictionary
        }
        }()

    var pixelBuffer: CVPixelBuffer?
    let err = CVPixelBufferCreate(kCFAllocatorDefault,
                                  Int(size.x),
                                  Int(size.y),
                                  pixelFormat,
                                  options as CFDictionary,
                                  &pixelBuffer)
    guard let img = pixelBuffer else {
        throw ComputeError.badInputData(description: "Unable to create CVPixelBuffer \(err)")
    }
    return PictureSample(ImageBuffer(img),
                         assetId: assetId,
                         workspaceId: workspaceId,
                         workspaceToken: workspaceToken,
                         time: TimePoint(0),
                         pts: TimePoint(0))
}

private func toCVPixelFormat( _ format: PixelFormat) throws -> OSType {
    switch format {
    case .nv12:
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case .BGRA, .RGBA:
        return kCVPixelFormatType_32BGRA
    case .yuvs:
        return kCVPixelFormatType_422YpCbCr8_yuvs
    case .zvuy:
        return kCVPixelFormatType_422YpCbCr8
    case .y420p:
        return kCVPixelFormatType_420YpCbCr8Planar
    default:
        throw ComputeError.badInputData(description: "Invalid pixel format")
    }
}
private func fromCVPixelFormat(_ pixelBuffer: CVPixelBuffer) -> PixelFormat {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    switch format {
    case kCVPixelFormatType_32BGRA:
        return .BGRA
    case kCVPixelFormatType_32RGBA:
        return .RGBA
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8PlanarFullRange:
        return .nv12
    case kCVPixelFormatType_422YpCbCr8_yuvs:
        return .yuvs
    case kCVPixelFormatType_422YpCbCr8:
        return .zvuy
    case kCVPixelFormatType_420YpCbCr8Planar:
        return .y420p
    default:
        return .invalid
    }
}
#endif
