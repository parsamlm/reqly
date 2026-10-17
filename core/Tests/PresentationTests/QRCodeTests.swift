import Testing

@testable import Presentation

@Suite struct QRCodeTests {
    @Test func picksTheSmallestVersionThatHoldsTheText() throws {
        #expect(try #require(QRCode("http://pc/")).size == 21)
        #expect(try #require(QRCode("http://192.168.100.200:65535/")).size == 29)
        #expect(try #require(QRCode(String(repeating: "a", count: 213))).size == 57)
        #expect(QRCode(String(repeating: "a", count: 214)) == nil)
    }

    @Test(arguments: [
        "http://192.168.1.125:9090/", "HELLO", String(repeating: "Reqly ", count: 20),
        String(repeating: "x", count: 150), String(repeating: "é", count: 70),
    ])
    func readsBackAsTheText(_ text: String) throws {
        let code = try #require(QRCode(text))
        #expect(Self.read(code) == Array(text.utf8))
    }

    @Test func drawsTheFinderAndTimingPatterns() throws {
        let code = try #require(QRCode("http://192.168.1.125:9090/"))
        let size = code.size
        for (x, y) in [(0, 0), (size - 7, 0), (0, size - 7)] {
            #expect(code.modules[y][x] && code.modules[y + 3][x + 3] && !code.modules[y + 1][x + 1])
            #expect(code.modules[y + 6][x + 6] && !code.modules[y + 5][x + 1])
        }
        #expect((8..<(size - 8)).allSatisfy { code.modules[6][$0] == ($0 % 2 == 0) })
        #expect((8..<(size - 8)).allSatisfy { code.modules[$0][6] == ($0 % 2 == 0) })
        #expect(code.modules[size - 8][8])
    }

    @Test func correctsErrors() {
        // A block's codewords, error correction included, are a multiple of the generator: the
        // polynomial is 0 at each of its roots.
        let data: [UInt8] = Array("Reqly".utf8)
        let divisor = ReedSolomon.divisor(degree: 10)
        let block = data + ReedSolomon.remainder(data, divisor: divisor)
        #expect(Self.syndromes(block, count: 10).allSatisfy { $0 == 0 })
        var damaged = block
        damaged[2] ^= 0x40
        #expect(!Self.syndromes(damaged, count: 10).allSatisfy { $0 == 0 })
    }

    // MARK: Reading a code back, as a scanner would, from its own layout

    /// The bytes a code holds: its format, then its codewords, unmasked, out of their blocks,
    /// each block checked against its error correction.
    static func read(_ code: QRCode) -> [UInt8]? {
        let version = (code.size - 17) / 4
        var layout = QRCode.Builder(version: version)
        layout.drawFunctionPatterns()
        // The first copy of the format, around the top left finder.
        var format = 0
        var positions: [(Int, Int)] = (0...5).map { (8, $0) } + [(8, 7), (8, 8), (7, 8)]
        positions += (9..<15).map { (14 - $0, 8) }
        for (index, (x, y)) in positions.enumerated() where code.modules[y][x] {
            format |= 1 << index
        }
        guard let mask = (0..<8).first(where: { QRCode.formatBits(mask: $0) == format }) else { return nil }
        var bits: [Bool] = []
        var right = code.size - 1
        while right >= 1 {
            if right == 6 {
                right = 5
            }
            for vertical in 0..<code.size {
                for offset in 0..<2 {
                    let x = right - offset
                    let y = (right + 1) & 2 == 0 ? code.size - 1 - vertical : vertical
                    if !layout.isFunction[y][x] {
                        bits.append(code.modules[y][x] != QRCode.Builder.masks(mask, x, y))
                    }
                }
            }
            right -= 2
        }
        let total = QRCode.totalCodewords[version - 1]
        let codewords = (0..<total).map { index in
            bits[(index * 8)..<(index * 8 + 8)].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) }
        }
        // Out of their blocks again: the data codewords, block by block, then the error correction.
        let count = QRCode.blocks[version - 1]
        let correction = QRCode.correctionPerBlock[version - 1]
        let shortBlocks = count - total % count
        let shortLength = total / count
        var blocks = (0..<count).map { _ in [UInt8]() }
        var next = 0
        for position in 0..<(shortLength + 1) {
            for index in 0..<count where position != shortLength - correction || index >= shortBlocks {
                blocks[index].append(codewords[next])
                next += 1
            }
        }
        var data: [UInt8] = []
        for block in blocks {
            guard syndromes(block, count: correction).allSatisfy({ $0 == 0 }) else { return nil }
            data += block.dropLast(correction)
        }
        // Byte mode, then the length, then the bytes.
        let stream: [Bool] = data.flatMap { byte in (0..<8).map { (byte >> (7 - $0)) & 1 == 1 } }
        func value(_ start: Int, _ count: Int) -> Int {
            stream[start..<start + count].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        }
        guard value(0, 4) == 0b0100 else { return nil }
        let lengthBits = version < 10 ? 8 : 16
        let length = value(4, lengthBits)
        return (0..<length).map { UInt8(value(4 + lengthBits + $0 * 8, 8)) }
    }

    /// The block's polynomial at the generator's roots, 2 to the powers 0, 1, 2 and on.
    static func syndromes(_ block: [UInt8], count: Int) -> [Int] {
        var root = 1
        return (0..<count).map { _ in
            let value = block.reduce(0) { ReedSolomon.multiply($0, root) ^ Int($1) }
            root = ReedSolomon.multiply(root, 2)
            return value
        }
    }
}

#if canImport(CoreImage)
    import CoreImage

    /// macOS's own detector reads the codes, as a phone's camera would.
    @Suite struct QRCodeScanTests {
        @Test(arguments: [
            "http://192.168.1.125:9090/", "http://10.0.0.7:65535/", String(repeating: "Reqly ", count: 30),
        ])
        func scansAsTheText(_ text: String) throws {
            let code = try #require(QRCode(text))
            let scale = 8
            let quiet = 4
            let width = (code.size + quiet * 2) * scale
            var pixels = [UInt8](repeating: 255, count: width * width)
            for (y, row) in code.modules.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    for dy in 0..<scale {
                        for dx in 0..<scale {
                            pixels[((y + quiet) * scale + dy) * width + (x + quiet) * scale + dx] = 0
                        }
                    }
                }
            }
            let image = try #require(
                pixels.withUnsafeMutableBytes { bytes in
                    CGContext(
                        data: bytes.baseAddress, width: width, height: width, bitsPerComponent: 8, bytesPerRow: width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?
                        .makeImage()
                })
            let detector = try #require(
                CIDetector(
                    ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let found = detector.features(in: CIImage(cgImage: image)).compactMap {
                ($0 as? CIQRCodeFeature)?.messageString
            }
            #expect(found == [text])
        }
    }
#endif
