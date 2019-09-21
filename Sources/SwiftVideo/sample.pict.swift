import VectorMath


#warning("TODO: Higher bit-depth color formats")
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

public enum Component {
    case r
    case g
    case b
    case a
    case y
    case cr
    case cb
}

public struct Plane {
    let size : Vector2
    let stride : Int
    let bitDepth : Int
    let components : [Component]
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
    func lock() -> ()
    func unlock() -> ()
    func revision() -> String
    func fillColor() -> Vector4
    func borderMatrix() -> Matrix4
    func opacity() -> Float
}

func componentsForPlane(_ pixelFormat: PixelFormat, _ idx: Int) -> [Component] {
    switch(pixelFormat) {
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
        default:
            return []
    }
}
