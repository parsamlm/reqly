import Foundation

/// Sizes as both apps write them, in decimal units as Finder and File Explorer use: `713 B`,
/// `4.1 KB`, `254 KB`, `1.2 MB`, with the digits grouped as the user's locale groups them.
public enum ByteCount {
    public static func text(_ bytes: Int64) -> String {
        guard bytes >= 1000 else { return "\(bytes.formatted()) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = value < 100 ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(units[unit])"
    }
}
