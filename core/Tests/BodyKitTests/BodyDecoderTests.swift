import BodyKit
import CZlib
import Foundation
import Testing

@Suite struct BodyDecoderTests {
    let hello = Data("hello".utf8)

    @Test func unpacksGzip() {
        let gzip = Data([
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x86,
            0xa6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00,
        ])
        #expect(BodyDecoder.decode(gzip, contentEncoding: "gzip") == hello)
    }

    @Test func unpacksDeflateWithOrWithoutTheZlibWrapper() {
        let zlib = Data([0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x06, 0x2c, 0x02, 0x15])
        let raw = Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00])
        #expect(BodyDecoder.decode(zlib, contentEncoding: "deflate") == hello)
        #expect(BodyDecoder.decode(raw, contentEncoding: "deflate") == hello)
    }

    @Test(
        .enabled(
            if: BodyDecoder.canDecode("br"),
            "Brotli comes from Apple's Compression framework, so only the Mac unpacks it for now."))
    func unpacksBrotli() {
        let brotli = Data([0x0b, 0x02, 0x80, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x03])
        #expect(BodyDecoder.decode(brotli, contentEncoding: "br") == hello)
    }

    @Test func leavesPlainBodiesAlone() {
        #expect(BodyDecoder.decode(hello, contentEncoding: nil) == hello)
        #expect(BodyDecoder.decode(hello, contentEncoding: "identity") == hello)
    }

    @Test func refusesWhatItCannotUnpack() {
        #expect(BodyDecoder.decode(hello, contentEncoding: "zstd") == nil)
        #expect(BodyDecoder.decode(hello, contentEncoding: "gzip") == nil)
        #expect(!BodyDecoder.canDecode("zstd"))
        #expect(BodyDecoder.canDecode("GZIP"))
    }

    @Test func stopsAtTheSizeLimit() throws {
        // 70 MB of zeros pack into about 70 KB, past the 64 MB an unpacked body may reach.
        let zeros = Data(count: 70 * 1024 * 1024)
        var packedSize = compressBound(uLong(zeros.count))
        var packed = Data(count: Int(packedSize))
        let status = packed.withUnsafeMutableBytes { output in
            zeros.withUnsafeBytes { input in
                compress2(
                    output.bindMemory(to: Bytef.self).baseAddress, &packedSize,
                    input.bindMemory(to: Bytef.self).baseAddress, uLong(zeros.count), Z_BEST_COMPRESSION)
            }
        }
        try #require(status == Z_OK)
        packed = packed.prefix(Int(packedSize))
        #expect(packed.count < 200_000)
        #expect(BodyDecoder.decode(packed, contentEncoding: "deflate") == nil)
        #expect(BodyDecoder.decode(packed.prefix(1000), contentEncoding: "deflate") == nil)
    }

    @Test func unpacksStackedEncodings() {
        let zlib = Data([0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x06, 0x2c, 0x02, 0x15])
        #expect(BodyDecoder.decode(zlib, contentEncoding: "identity, deflate") == hello)
    }

    @Test func noticesABodyThatWasCutShort() {
        let cut = Data([
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        #expect(BodyDecoder.decode(cut, contentEncoding: "gzip") == nil)
    }
}

@Suite struct DeflateStreamTests {
    /// Two WebSocket messages compressed with permessage-deflate. The second one refers back to
    /// the first, so it unpacks only with what came before.
    @Test func unpacksMessagesThatReferToEarlierOnes() throws {
        let first: [UInt8] = [
            170, 86, 74, 206, 44, 169, 84, 178, 82, 114, 204, 45, 46, 73, 45, 74, 73, 204, 85, 210, 81, 42, 73, 205,
            45, 72, 45, 74, 44, 41, 45, 74, 85, 178, 50, 52, 209, 51, 170, 5, 0,
        ]
        let second: [UInt8] = [170, 38, 70, 153, 113, 45, 0]
        let end: [UInt8] = [0x00, 0x00, 0xff, 0xff]
        let stream = DeflateStream()
        let one = try #require(stream.decompress(Data(first + end)))
        #expect(String(decoding: one, as: UTF8.self) == #"{"city":"Amsterdam","temperature":14.2}"#)
        let two = try #require(stream.decompress(Data(second + end)))
        #expect(String(decoding: two, as: UTF8.self) == #"{"city":"Amsterdam","temperature":14.3}"#)
        // On its own, the second message doesn't unpack to the same text.
        let alone = DeflateStream().decompress(Data(second + end))
        #expect(alone.map { String(decoding: $0, as: UTF8.self) } != #"{"city":"Amsterdam","temperature":14.3}"#)
    }
}
