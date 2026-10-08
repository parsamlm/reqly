import Foundation

/// A version such as `1.2` or `1.10.1`, compared number by number, so `1.10` comes after `1.9`.
/// Release tags may start with a `v`, as in `v1.2.0`.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let numbers: [Int]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        self.numbers = numbers
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    /// `1.2` and `1.2.0` are the same version.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var numbers = numbers
        while numbers.last == 0 {
            numbers.removeLast()
        }
        hasher.combine(numbers)
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".")
    }
}
