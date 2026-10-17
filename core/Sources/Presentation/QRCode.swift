/// A QR code for a short text, such as the setup page's address, for a phone's camera to scan. It
/// uses byte mode and error correction level M, the Mac's choice, in versions 1 to 10, which hold
/// up to 213 bytes. The Mac draws its codes with CoreImage; Windows draws these.
public struct QRCode: Hashable, Sendable {
    /// The modules, row by row, `true` for dark. Without the quiet zone around them.
    public let modules: [[Bool]]

    public var size: Int { modules.count }

    /// `nil` for a text too long for version 10.
    public init?(_ text: String) {
        let data = Array(text.utf8)
        guard let version = (1...10).first(where: { Self.dataCodewords($0) * 8 >= Self.bitsNeeded(data.count, $0) })
        else { return nil }
        var builder = Builder(version: version)
        builder.drawFunctionPatterns()
        builder.drawCodewords(Self.interleaved(Self.codewords(data, version: version), version: version))
        modules = builder.withBestMask()
    }

    // MARK: Codewords

    /// Error correction codewords in each block, at level M, for versions 1 to 10.
    static let correctionPerBlock = [10, 16, 26, 18, 24, 16, 18, 22, 22, 26]
    /// Blocks the codewords are split into, at level M.
    static let blocks = [1, 1, 1, 2, 2, 4, 4, 4, 5, 5]
    /// Every codeword a version holds, data and error correction.
    static let totalCodewords = [26, 44, 70, 100, 134, 172, 196, 242, 292, 346]

    static func dataCodewords(_ version: Int) -> Int {
        totalCodewords[version - 1] - blocks[version - 1] * correctionPerBlock[version - 1]
    }

    /// The mode, the length, and the bytes. Versions from 10 count the length in 16 bits.
    static func bitsNeeded(_ count: Int, _ version: Int) -> Int {
        4 + (version < 10 ? 8 : 16) + count * 8
    }

    /// The data codewords: byte mode, the length, the bytes, then the end and the padding.
    static func codewords(_ data: [UInt8], version: Int) -> [UInt8] {
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for index in (0..<count).reversed() {
                bits.append((value >> index) & 1 == 1)
            }
        }
        append(0b0100, 4)
        append(data.count, version < 10 ? 8 : 16)
        for byte in data {
            append(Int(byte), 8)
        }
        let capacity = dataCodewords(version) * 8
        append(0, min(4, capacity - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var codewords = stride(from: 0, to: bits.count, by: 8).map { start in
            bits[start..<start + 8].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) }
        }
        var pad: UInt8 = 0xEC
        while codewords.count < dataCodewords(version) {
            codewords.append(pad)
            pad = pad == 0xEC ? 0x11 : 0xEC
        }
        return codewords
    }

    /// The data split into blocks, each followed by its error correction, read one codeword of
    /// each block at a time. Shorter blocks come first.
    static func interleaved(_ data: [UInt8], version: Int) -> [UInt8] {
        let count = blocks[version - 1]
        let correction = correctionPerBlock[version - 1]
        let total = totalCodewords[version - 1]
        let shortBlocks = count - total % count
        let shortLength = total / count
        let divisor = ReedSolomon.divisor(degree: correction)
        var split: [[UInt8]] = []
        var offset = 0
        for index in 0..<count {
            let length = shortLength - correction + (index < shortBlocks ? 0 : 1)
            let block = Array(data[offset..<offset + length])
            offset += length
            // Short blocks get a byte of padding, so every block's error correction lines up.
            let padding = Array(repeating: UInt8(0), count: shortLength + 1 - correction - length)
            split.append(block + padding + ReedSolomon.remainder(block, divisor: divisor))
        }
        var result: [UInt8] = []
        for position in 0..<(shortLength + 1) {
            for (index, block) in split.enumerated() where position != shortLength - correction || index >= shortBlocks
            {
                result.append(block[position])
            }
        }
        return result
    }

    // MARK: Format

    /// Error correction level M, then the mask, with their own error correction.
    static func formatBits(mask: Int) -> Int {
        let data = 0b00 << 3 | mask
        var remainder = data
        for _ in 0..<10 {
            remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537)
        }
        return (data << 10 | remainder) ^ 0x5412
    }

    /// The version, with its own error correction, for versions from 7.
    static func versionBits(_ version: Int) -> Int {
        var remainder = version
        for _ in 0..<12 {
            remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25)
        }
        return version << 12 | remainder
    }

    /// Where the alignment patterns' centers are, across and down, for versions 1 to 10.
    static let alignment: [[Int]] = [
        [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
    ]

    // MARK: The matrix

    struct Builder {
        let version: Int
        let size: Int
        var modules: [[Bool]]
        /// Modules the patterns and the format take, which hold no data and aren't masked.
        var isFunction: [[Bool]]

        init(version: Int) {
            self.version = version
            size = version * 4 + 17
            modules = Array(repeating: Array(repeating: false, count: size), count: size)
            isFunction = modules
        }

        mutating func set(_ x: Int, _ y: Int, _ dark: Bool) {
            modules[y][x] = dark
            isFunction[y][x] = true
        }

        mutating func drawFunctionPatterns() {
            for index in 0..<size {
                set(6, index, index % 2 == 0)
                set(index, 6, index % 2 == 0)
            }
            for (x, y) in [(3, 3), (size - 4, 3), (3, size - 4)] {
                for dy in -4...4 {
                    for dx in -4...4 where (0..<size).contains(x + dx) && (0..<size).contains(y + dy) {
                        let distance = max(abs(dx), abs(dy))
                        set(x + dx, y + dy, distance != 2 && distance != 4)
                    }
                }
            }
            let positions = QRCode.alignment[version - 1]
            for (row, y) in positions.enumerated() {
                for (column, x) in positions.enumerated() {
                    // Not where the finder patterns are.
                    let last = positions.count - 1
                    if (row == 0 && column == 0) || (row == 0 && column == last) || (row == last && column == 0) {
                        continue
                    }
                    for dy in -2...2 {
                        for dx in -2...2 {
                            set(x + dx, y + dy, max(abs(dx), abs(dy)) != 1)
                        }
                    }
                }
            }
            drawFormat(mask: 0)
            if version >= 7 {
                let bits = QRCode.versionBits(version)
                for index in 0..<18 {
                    let dark = (bits >> index) & 1 == 1
                    let a = size - 11 + index % 3
                    let b = index / 3
                    set(a, b, dark)
                    set(b, a, dark)
                }
            }
        }

        /// Both copies of the format, and the dark module beside the bottom left finder.
        mutating func drawFormat(mask: Int) {
            let bits = QRCode.formatBits(mask: mask)
            func bit(_ index: Int) -> Bool { (bits >> index) & 1 == 1 }
            for index in 0...5 {
                set(8, index, bit(index))
            }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for index in 9..<15 {
                set(14 - index, 8, bit(index))
            }
            for index in 0..<8 {
                set(size - 1 - index, 8, bit(index))
            }
            for index in 8..<15 {
                set(8, size - 15 + index, bit(index))
            }
            set(8, size - 8, true)
        }

        /// The codewords' bits, in two-module columns from the bottom right, up then down.
        mutating func drawCodewords(_ codewords: [UInt8]) {
            var index = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 {
                    right = 5
                }
                for vertical in 0..<size {
                    for offset in 0..<2 {
                        let x = right - offset
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vertical : vertical
                        guard !isFunction[y][x], index < codewords.count * 8 else { continue }
                        modules[y][x] = (codewords[index >> 3] >> (7 - (index & 7))) & 1 == 1
                        index += 1
                    }
                }
                right -= 2
            }
        }

        static func masks(_ mask: Int, _ x: Int, _ y: Int) -> Bool {
            switch mask {
            case 0: (x + y) % 2 == 0
            case 1: y % 2 == 0
            case 2: x % 3 == 0
            case 3: (x + y) % 3 == 0
            case 4: (x / 3 + y / 2) % 2 == 0
            case 5: x * y % 2 + x * y % 3 == 0
            case 6: (x * y % 2 + x * y % 3) % 2 == 0
            default: ((x + y) % 2 + x * y % 3) % 2 == 0
            }
        }

        func masked(_ mask: Int) -> Builder {
            var result = self
            for y in 0..<size {
                for x in 0..<size where !isFunction[y][x] && Self.masks(mask, x, y) {
                    result.modules[y][x].toggle()
                }
            }
            result.drawFormat(mask: mask)
            return result
        }

        /// The modules with the mask that leaves the fewest patterns a scanner could mistake.
        func withBestMask() -> [[Bool]] {
            (0..<8).map { masked($0) }.min { $0.penalty < $1.penalty }!.modules
        }

        /// What the standard counts against a mask: long runs, blocks, finder-like rows, and imbalance.
        var penalty: Int {
            var score = 0
            let columns = (0..<size).map { x in modules.map { $0[x] } }
            for line in modules + columns {
                var run = 1
                for index in 1..<size {
                    if line[index] == line[index - 1] {
                        run += 1
                    } else {
                        score += run >= 5 ? run - 2 : 0
                        run = 1
                    }
                }
                score += run >= 5 ? run - 2 : 0
                let pattern = [true, false, true, true, true, false, true]
                for start in 0..<(size - 6) where Array(line[start..<start + 7]) == pattern {
                    let before = start >= 4 && !line[(start - 4)..<start].contains(true)
                    let after = start + 11 <= size && !line[(start + 7)..<(start + 11)].contains(true)
                    if before || after {
                        score += 40
                    }
                }
            }
            for y in 0..<(size - 1) {
                for x in 0..<(size - 1) {
                    let color = modules[y][x]
                    if color == modules[y][x + 1], color == modules[y + 1][x], color == modules[y + 1][x + 1] {
                        score += 3
                    }
                }
            }
            let dark = modules.reduce(0) { $0 + $1.filter { $0 }.count }
            let total = size * size
            score += ((abs(dark * 20 - total * 10) + total - 1) / total - 1) * 10
            return score
        }
    }
}

/// Reed-Solomon error correction over GF(256), as QR codes use it.
enum ReedSolomon {
    static func multiply(_ x: Int, _ y: Int) -> Int {
        var product = 0
        for bit in (0...7).reversed() {
            product = (product << 1) ^ ((product >> 7) * 0x11D)
            product ^= ((y >> bit) & 1) * x
        }
        return product
    }

    /// The generator polynomial of a degree, highest power first, without its leading 1.
    static func divisor(degree: Int) -> [UInt8] {
        var result = Array(repeating: 0, count: degree)
        result[degree - 1] = 1
        var root = 1
        for _ in 0..<degree {
            for index in 0..<degree {
                result[index] = multiply(result[index], root)
                if index + 1 < degree {
                    result[index] ^= result[index + 1]
                }
            }
            root = multiply(root, 0x02)
        }
        return result.map(UInt8.init)
    }

    /// The error correction codewords for a block of data.
    static func remainder(_ data: [UInt8], divisor: [UInt8]) -> [UInt8] {
        var result = Array(repeating: 0, count: divisor.count)
        for byte in data {
            let factor = Int(byte) ^ result[0]
            result.removeFirst()
            result.append(0)
            for index in result.indices {
                result[index] ^= multiply(Int(divisor[index]), factor)
            }
        }
        return result.map(UInt8.init)
    }
}
