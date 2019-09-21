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

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
