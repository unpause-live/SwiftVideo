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

import Foundation

public class Weak<T: AnyObject> {
  public weak var value : T?
  public var uuid: String?
  public init (value: T, uuid: String? = nil) {
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
    public func toJSON<T: Decodable>(_ as: T.Type) throws -> T {
        guard let data = self.data(using: .utf8, allowLossyConversion: false) else { throw ConversionError.cannotConvertToData }
        return try JSONDecoder().decode(T.self, from: data)
    }
}