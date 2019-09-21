import Foundation

class Weak<T: AnyObject> {
  weak var value : T?
  var uuid: String?
  init (value: T, uuid: String? = nil) {
    self.value = value
    self.uuid = uuid
  }
}

public func bridge<T: AnyObject>(_ obj: T) -> UnsafeMutableRawPointer {
    return Unmanaged.passUnretained(obj).toOpaque()
}
public func bridge<T : AnyObject>(ptr : UnsafeMutableRawPointer) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
}

enum ConversionError: Error {
    case cannotConvertToData
}

extension String {
    func toJSON<T: Decodable>(_ as: T.Type) throws -> T {
        guard let data = self.data(using: .utf8, allowLossyConversion: false) else { throw ConversionError.cannotConvertToData }
        return try JSONDecoder().decode(T.self, from: data)
    }
}