import BodyKit
import Foundation
import Presentation
import ReqlyModel
import Testing

@testable import ReqlyApp

@Suite struct BodyWordsTests {
    static let english = Locale(identifier: "en_US")

    static func body(_ text: String, _ type: String, encoding: String? = nil, data: Data? = nil) -> BodyPresentation {
        var fields = [HeaderField(name: "Content-Type", value: type)]
        if let encoding {
            fields.append(HeaderField(name: "Content-Encoding", value: encoding))
        }
        return BodyPresentation(data: data ?? Data(text.utf8), headers: Headers(fields), rootLabel: "Response")
    }

    static func titles(_ body: BodyPresentation) -> [String] {
        body.modes.map { BodyWords.title(of: $0, in: body) }
    }

    @Test func saysWhatABodyIsAsTheMacDoes() {
        let json = Self.body(#"{"city":"Tehran","high":31}"#, "application/json")
        #expect(BodyWords.summary(json) == "JSON · 27 B")
        #expect(Self.titles(json) == ["Formatted", "Tree", "Raw", "Hex"])
        #expect(Self.titles(Self.body("<a/>", "application/xml")) == ["Formatted", "Raw", "Hex"])
        #expect(Self.titles(Self.body("<p>Hi</p>", "text/html")) == ["Raw", "Hex"])
        #expect(Self.titles(Self.body("Clear skies.", "text/plain")) == ["Text", "Hex"])
        #expect(
            Self.titles(Self.body("city=Tehran&days=3", "application/x-www-form-urlencoded")) == ["Form", "Raw", "Hex"])
        let image = Self.body("", "image/png", data: Data(TestServer.png))
        #expect(Self.titles(image) == ["Preview", "Hex"])
        #expect(BodyWords.summary(image) == "PNG · \(TestServer.png.count) B")
        #expect(Self.titles(Self.body("", "application/octet-stream", data: Data([0, 1, 2, 0xFF]))) == ["Hex"])

        let broken = Self.body(#"{"city": "Tehran","#, "application/json")
        #expect(Self.titles(broken) == ["Raw", "Hex"])
        #expect(broken.note?.hasPrefix("This isn't valid JSON") == true)
        #expect(BodyWords.empty(.request) == "This request has no body.")
        #expect(BodyWords.empty(.response) == "This response has no body.")
    }

    @Test func notesWhatWasUnpackedAndWhatsCutShort() {
        let packed = Data(
            base64Encoded:
                "H4sIAAAAAAAC/6tWSs4sqVSyUgpJzShKzFPSUSpITM5OTVGyKikqTdVRSkmsLFayiq5WKs4GqUrOSU0sAirKyEzPULIyNqzVgckUJWbmwSWMTGpjawGs06nOWwAAAA=="
        )!
        let body = Self.body("", "application/json", encoding: "gzip", data: packed)
        #expect(body.unpackedFrom == "gzip")
        #expect(BodyWords.summary(body) == "JSON · \(packed.count) B")
        #expect(
            BodyWords.footnotes(body) == ["Unpacked from gzip: \(packed.count) B became \(body.content.count) B."])
        #expect(BodyWords.footnotes(Self.body("{}", "application/json")).isEmpty)

        let text = CodeText(
            text: (1...12).map { "line \($0)" }.joined(separator: "\n"), tokens: [], isCode: true, lineLimit: 5)
        #expect(BodyWords.start(of: text, locale: Self.english) == "Showing the first 5 lines of 12.")
        let line = CodeText(text: String(repeating: "a", count: 3_000), tokens: [], isCode: true, byteLimit: 900)
        #expect(BodyWords.start(of: line, locale: Self.english) == "Showing the first 900 B of 3.0 KB.")
    }

    @Test func describesAFormsParts() throws {
        let boundary = "reqly"
        let form = Data(
            ("--\(boundary)\r\nContent-Disposition: form-data; name=\"city\"\r\n\r\nTehran\r\n--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"map\"; filename=\"map.png\"\r\nContent-Type: image/png\r\n\r\n"
                + "PNGDATA\r\n--\(boundary)\r\nContent-Disposition: form-data\r\nContent-Type: application/octet-stream"
                + "\r\n\r\n\u{1}\u{2}\r\n--\(boundary)--\r\n").utf8)
        let body = Self.body("", "multipart/form-data; boundary=\(boundary)", data: form)
        #expect(Self.titles(body) == ["Form", "Hex"])
        let parts = try #require(body.parts)
        #expect(parts.map(BodyWords.name(of:)) == ["city", "map", "Unnamed part"])
        #expect(BodyWords.describe(parts[0]) == "Tehran")
        #expect(BodyWords.describe(parts[1]) == "map.png · image/png · 7 B")
        #expect(BodyWords.noFields == "This form has no fields.")
    }

    @Test func describesAPicture() {
        #expect(BodyWords.format(.png, hasAlpha: true) == "PNG, with transparency")
        #expect(BodyWords.format(.jpeg, hasAlpha: false) == "JPEG")
        #expect(BodyWords.dimensions(width: 1_600, height: 1_200, locale: Self.english) == "1,600 × 1,200 pixels")
        #expect(
            BodyWords.dimensions(width: 32, height: 24, fileName: "icon@2x.png", locale: Self.english)
                == "32 × 24 pixels (16 × 12 points at 2x)")
        #expect(BodyWords.fileName(for: .png, url: URL(string: "http://127.0.0.1/maps/tehran.png")) == "tehran.png")
        #expect(BodyWords.fileName(for: .png, url: URL(string: "http://127.0.0.1/image")) == "image.png")
        #expect(BodyWords.fileName(for: .webp, url: nil) == "image.webp")
    }

    @Test func countsBytesExactly() {
        #expect(BodyWords.bytes(1) == "1 byte")
        #expect(BodyWords.bytes(12_871, locale: Self.english) == "12,871 bytes")
        #expect(BodyWords.selected(16..<48, locale: Self.english) == "32 bytes selected at offset 16")
    }
}
