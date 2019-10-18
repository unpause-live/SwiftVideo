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

import VectorMath

// TODO: Higher bit-depth formats
public enum PixelFormat {
    case nv12
    case nv21
    case yuvs
    case zvuy
    case y420p
    case y422p
    case y444p
    case RGBA
    case BGRA
    case shape
    case text
    case invalid
}

// swiftlint:disable identifier_name
public enum Component {
    case r
    case g
    case b
    case a
    case y
    case cr
    case cb
}
// swiftlint:enable identifier_name

public struct Plane {
    public init(size: Vector2, stride: Int, bitDepth: Int, components: [Component]) {
        self.size = size
        self.stride = stride
        self.bitDepth = bitDepth
        self.components = components
    }
    let size: Vector2
    let stride: Int
    let bitDepth: Int
    let components: [Component]
}

public enum BufferType {
    case shared
    case cpu
    case gpu
    case invalid
}

public protocol PictureEvent: Event {
    func pts() -> TimePoint
    func matrix() -> Matrix4
    func textureMatrix() -> Matrix4
    func zIndex() -> Int
    func pixelFormat() -> PixelFormat
    func bufferType() -> BufferType
    func size() -> Vector2
    func lock()
    func unlock()
    func revision() -> String
    func fillColor() -> Vector4
    func borderMatrix() -> Matrix4
    func opacity() -> Float
}

public func componentsForPlane(_ pixelFormat: PixelFormat, _ idx: Int) -> [Component] {
    switch pixelFormat {
    case .y420p, .y422p, .y444p:
        return [[.y], [.cb], [.cr]][idx]
    case .nv12:
        return [[.y], [.cb, .cr]][idx]
    case .nv21:
        return [[.y], [.cr, .cb]][idx]
    case .yuvs:
        return [.y, .cb, .y, .cr]
    case .zvuy:
        return [.cb, .y, .cr, .y]
    case .BGRA:
        return [.b, .g, .r, .a]
    case .RGBA:
        return [.r, .g, .b, .a]
    default:
        return []
    }
}
