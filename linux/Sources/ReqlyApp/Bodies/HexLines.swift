import Foundation

/// Bytes laid out as the hex view's lines, as the Mac's hex view draws them: an offset, the bytes
/// in hex in groups of eight, and the same bytes as text, a dot for each that isn't printable
/// ASCII. Each line is text a screen reader reads as it is, such as
/// `000010  48 54 54 50 2F 31 2E 31  20 32 30 30 20 4F 4B 0D  HTTP/1.1 200 OK.`
enum HexLines {
    /// A line has 16 bytes, or 8 when 16 don't fit.
    static let wide = 16
    static let narrow = 8

    static func count(size: Int, perLine: Int) -> Int {
        (size + perLine - 1) / perLine
    }

    /// Offsets take six digits below 16 MB, as on the Mac, which leaves room for all 16 bytes in
    /// details of usual width, and eight from there.
    static func offsetDigits(size: Int) -> Int {
        size > 0xFF_FFFF ? 8 : 6
    }

    /// How many characters a line of `perLine` bytes takes.
    static func width(perLine: Int, size: Int) -> Int {
        offsetDigits(size: size) + 2 + hexWidth(perLine) + 2 + perLine
    }

    /// The line that starts at byte `offset`, of `bytes`, which are the line's own and may be
    /// fewer than `perLine` on the last. The hex of a short line is padded, so its text lines up
    /// with the text of the lines above.
    static func line(at offset: Int, _ bytes: some Collection<UInt8>, perLine: Int, size: Int) -> String {
        let digits = String(offset, radix: 16, uppercase: true)
        var line = String(repeating: "0", count: max(0, offsetDigits(size: size) - digits.count)) + digits + "  "
        var hex = ""
        var text = ""
        for (position, byte) in bytes.prefix(perLine).enumerated() {
            if position > 0 {
                hex += position.isMultiple(of: 8) ? "  " : " "
            }
            hex += hexDigits[Int(byte >> 4)]
            hex += hexDigits[Int(byte & 0x0F)]
            text.append((0x20..<0x7F).contains(byte) ? Character(Unicode.Scalar(byte)) : ".")
        }
        line += hex + String(repeating: " ", count: hexWidth(perLine) - hex.count) + "  " + text
        return line
    }

    /// Bytes as Copy as Hex copies them, as the Mac does: `48 54 54 50`.
    static func hex(_ bytes: some Collection<UInt8>) -> String {
        var text = ""
        text.reserveCapacity(bytes.count * 3)
        for byte in bytes {
            if !text.isEmpty {
                text += " "
            }
            text += hexDigits[Int(byte >> 4)]
            text += hexDigits[Int(byte & 0x0F)]
        }
        return text
    }

    /// The hex of `perLine` bytes: two digits each, a space between, and a second one between
    /// each group of eight.
    private static func hexWidth(_ perLine: Int) -> Int {
        perLine * 3 - 1 + (perLine - 1) / 8
    }

    private static let hexDigits = Array("0123456789ABCDEF").map(String.init)
}
