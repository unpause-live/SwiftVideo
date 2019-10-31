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

import CFreeType
import Foundation
import VectorMath
#if !os(Linux)
import CoreVideo
#endif

private class FreeTypeInit {
    static let library: FT_Library? = {
        var library: FT_Library?
        FT_Init_FreeType(&library)
        return library
    }()
}

public class TextSample: Event {
    public func type() -> String {
        return "text"
    }
    public func time() -> TimePoint {
        return TimePoint(0, 1000)
    }
    public func assetId() -> String {
        return idAsset
    }
    public func workspaceId() -> String {
        return idWorkspace
    }
    public func workspaceToken() -> String? {
        return tokenWorkspace
    }
    public func info() -> EventInfo? {
        return meta
    }
    public func value() -> String {
        return val
    }
    public func pixelSize() -> Int {
        return size
    }
    public func textColor() -> Vector4 {
        return color
    }
    public init(_ value: String,
                _ pixelSize: Int,
                assetId: String,
                workspaceId: String,
                workspaceToken: String? = nil,
                color: Vector4 = Vector4(1.0, 1.0, 1.0, 1.0),
                pts: TimePoint? = nil,
                info: EventInfo? = nil) {
                self.val = value
                self.idAsset = assetId
                self.tokenWorkspace = workspaceToken
                self.idWorkspace = workspaceId
                self.meta = info
                self.size = pixelSize
                self.color = color
    }
    let idAsset: String
    let idWorkspace: String
    let tokenWorkspace: String?
    let val: String
    let meta: EventInfo?
    let size: Int
    let color: Vector4
}

public enum TextError: Error {
    case ftError(Int32)
    case invalidUrl
    case invalidBuffer
    case unknown
}

public class TextRenderer: Tx<TextSample, PictureSample> {
    public init(_ clock: Clock,
                _ fontUrl: String) throws {
        let library = FreeTypeInit.library
        self.library = library
        if let url = URL(string: fontUrl) {
            let fontData = try Data(contentsOf: url, options: [.uncached])
            let face: FT_Face = try fontData.withUnsafeBytes {
                var face: FT_Face?
                let base = $0.bindMemory(to: UInt8.self)
                let result = FT_New_Memory_Face(library, base.baseAddress, $0.count, 0, &face)

                if result != 0 {
                    dump(fontData)
                    throw TextError.ftError(result)
                }
                if let face = face {
                    return face
                }
                throw TextError.unknown
            }
            self.fontData = fontData
            self.fontFace = face
        } else {
            throw TextError.invalidUrl
        }
        super.init()
        super.set { [weak self] in
            guard let strongSelf = self else {
                return .gone
            }
            return strongSelf.handle($0)
        }
    }

    deinit {
        FT_Done_Face(fontFace)
        print("TextRenderer deinit")
    }

    func handle(_ sample: TextSample) -> EventBox<PictureSample> {
        FT_Set_Char_Size(fontFace, 0, sample.pixelSize() * 64, 0, 0)
        FT_Select_Charmap(fontFace, FT_ENCODING_UNICODE)
        let width = textWidth(sample.value(), fontFace)
        let props = FontProperties(Int(self.fontFace.pointee.size.pointee.metrics.ascender / 64),
                        Int(self.fontFace.pointee.size.pointee.metrics.descender / 64),
                        color: sample.textColor())
        do {
            let pic = try createPictureSample(Vector2(Float(width),
                            Float(props.height)),
                            .RGBA,
                            assetId: sample.assetId(),
                            workspaceId: sample.workspaceId(),
                            workspaceToken: sample.workspaceToken())
#if !os(Linux)
            pic.lock()
            defer { pic.unlock() }
#endif
            // Destructuring in Swift doesn't allow you to mix mutable and immutable values unless you use
            // a Switch statement.
            switch try backingBuffer(pic, height: props.height) {
            case (var buffer, let stride):
                renderText(sample.value(), buffer: &buffer, fontFace: fontFace, fontProps: props, stride: stride)
            }
#if os(Linux)
            return .just(PictureSample(pic, img: ImageBuffer(imageBuffer, buffers: [buffer])))
#else
            return .just(pic)
#endif
        } catch {
            return .error(EventError("text", -1, "\(error)", assetId: sample.assetId()))
        }
    }
    let fontData: Data
    let fontFace: FT_Face
    let library: FT_Library?
}

#if os(Linux)
private typealias BackingType = Data
#else
private typealias BackingType = UnsafeMutablePointer<UInt8>
#endif

private func backingBuffer(_ pic: PictureSample, height: Int) throws -> (BackingType, Int) {
#if os(Linux)
    guard let imageBuffer = pic.imageBuffer(),
          let buffer = imageBuffer.buffers[safe: 0] else {
        throw TextError.invalidBuffer
    }
    let stride = width * 4
    return (buffer, stride)
#else
    guard let imageBuffer = pic.imageBuffer(),
          let rawPointer = CVPixelBufferGetBaseAddress(imageBuffer.pixelBuffer) else {
        throw TextError.invalidBuffer
    }
    let stride = CVPixelBufferGetBytesPerRow(imageBuffer.pixelBuffer)
    let buffer = rawPointer.bindMemory(to: UInt8.self, capacity: stride * height)
    return (buffer, stride)
#endif
}

private struct FontProperties {
    init(_ ascender: Int, _ descender: Int, color: Vector4) {
        height = ascender + descender
        self.ascender = ascender
        self.descender = descender
        self.color = color
    }
    let height: Int
    let ascender: Int
    let descender: Int
    let color: Vector4
}

private func renderText(_ text: String,
                        buffer: inout BackingType,
                        fontFace: FT_Face,
                        fontProps: FontProperties,
                        stride: Int) {
    _ = text.unicodeScalars.reduce(0) { (lhs: Int, unic: Unicode.Scalar) -> Int in
        let idx = FT_Get_Char_Index(fontFace, FT_ULong(unic.value))
        if FT_Load_Glyph(fontFace, idx, FT_Int32(FT_LOAD_RENDER)) != 0 {
            return lhs
        }
        let face = fontFace.pointee
        guard let glyph = face.glyph?.pointee else {
            return lhs
        }
        if let bitmap = glyph.bitmap.buffer {
            let top = max(fontProps.ascender - Int(glyph.bitmap_top), 0)
            // swiftlint:disable identifier_name
            for y in top..<min(top+Int(glyph.bitmap.rows), fontProps.height) {
                for x in lhs+Int(glyph.bitmap_left)..<min(lhs+Int(glyph.bitmap_left)+Int(glyph.bitmap.width),
                        stride) {
                    let srcx = x - (lhs+Int(glyph.bitmap_left))
                    let srcy = y - top
                    let srcIdx = Int(glyph.bitmap.width) * srcy + srcx
                    let dstIdx = stride * y + x * 4
                    let gray = bitmap[srcIdx]
                    buffer[dstIdx] = UInt8(Float(gray) * clamp(fontProps.color.x, 0.0, 1.0))
                    buffer[dstIdx+1] = UInt8(Float(gray) * clamp(fontProps.color.y, 0.0, 1.0))
                    buffer[dstIdx+2] = UInt8(Float(gray) * clamp(fontProps.color.z, 0.0, 1.0))
                    buffer[dstIdx+3] = gray
                }
            }
            // swiftlint:enable identifier_name
        }
        return lhs + Int(glyph.advance.x >> 6) + ((glyph.advance.x & 0x3f) > 31 ? 1 : 0)
    }
}

private func textWidth(_ text: String, _ fontFace: FT_Face) -> Int {
    text.unicodeScalars.reduce(0) { acc, next in
        let idx = FT_Get_Char_Index(fontFace, FT_ULong(next.value))
        if FT_Load_Glyph(fontFace, idx, FT_Int32(FT_LOAD_RENDER)) != 0 {
            return acc
        }
        let face = fontFace.pointee
        guard let glyph = face.glyph?.pointee else {
            return acc
        }
        let width = acc + Int(glyph.advance.x >> 6) + ((glyph.advance.x & 0x3f) > 31 ? 1 : 0)
        return width
    }
}
