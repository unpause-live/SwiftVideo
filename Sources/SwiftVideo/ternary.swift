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

// "ternary unwrapping operator"
// https://dev.to/danielinoa_/ternary-unwrapping-in-swift-903
precedencegroup Group { associativity: right }

infix operator <??>: Group
func <??> <I, O>(_ input: I?,
                 _ handler: (lhs: (I) -> O, rhs: () -> O)) -> O {
    guard let input = input else {
        return handler.rhs()
    }
    return handler.lhs(input)
}

infix operator <|>: Group
func <|> <I, O>(_ lhs: @escaping (I) -> O,
                _ rhs: @autoclosure @escaping () -> O) -> ((I) -> O, () -> O) {
    return (lhs, rhs)
}

public extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
