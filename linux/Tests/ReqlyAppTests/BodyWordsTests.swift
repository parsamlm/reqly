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

    /// The server names the file a picture is saved or opened as, so the name can't lead out of
    /// its folder, hide as a dot file, or open as anything but a picture.
    @Test func namesAPicturesFileOnlyAsAPicture() {
        func name(_ format: ImageFormat, _ url: String) -> String {
            BodyWords.fileName(for: format, url: URL(string: url))
        }
        let away = "http://example.com/img/..%2F..%2F..%2Fhome%2Fu%2F.config%2Fautostart%2Fx.desktop"
        #expect(name(.png, away) == "x.png")
        #expect(name(.png, "http://example.com/x.jar") == "x.png")
        #expect(name(.png, "http://example.com/.bashrc") == "image.png")
        #expect(name(.png, "http://example.com/a/%2E%2E") == "image.png")
        #expect(name(.png, "http://example.com/") == "image.png")
        #expect(name(.jpeg, "http://example.com/photo.JPG") == "photo.JPG")
        #expect(name(.jpeg, "http://example.com/photo.jpeg") == "photo.jpeg")
        #expect(name(.jpeg, "http://example.com/photo") == "image.jpeg")
        #expect(name(.icon, "http://example.com/favicon.ico") == "favicon.ico")
        #expect(name(.tiff, "http://example.com/scan.tif") == "scan.tif")
        #expect(name(.svg, "http://example.com/logo.svg.png") == "logo.svg.svg")
    }

    /// A long name is cut short, at a character's end, keeping its extension, so the file can be
    /// written: file systems take 255 bytes.
    @Test func cutsALongFileName() {
        func name(_ format: ImageFormat, _ last: String) -> String {
            BodyWords.fileName(for: format, url: URL(string: "http://example.com/")?.appending(path: last))
        }
        let long = name(.png, String(repeating: "a", count: 300) + ".png")
        #expect(long == String(repeating: "a", count: 196) + ".png")
        #expect(name(.jpeg, String(repeating: "b", count: 300) + ".JPG").hasSuffix("b.JPG"))
        #expect(name(.jpeg, String(repeating: "b", count: 300) + ".JPG").utf8.count == 200)
        // Two bytes a letter: 97 letters of 2 bytes, then ".webp", fits; 98 wouldn't.
        let persian = name(.webp, String(repeating: "ش", count: 150) + ".gif")
        #expect(persian == String(repeating: "ش", count: 97) + ".webp")
        #expect(name(.png, "short.png") == "short.png")
        // One character of 201 bytes, an e with 100 accents: too long alone, so not ".png", a dot file.
        let accented = "e" + String(repeating: "\u{0301}", count: 100)
        #expect(accented.count == 1)
        #expect(name(.png, accented + ".png") == "image.png")
    }

    /// A picture to open goes in Reqly's folder in your runtime folder, which only you can open,
    /// or in your cache folder, never in the temporary folder others share.
    @MainActor @Test func opensAPictureFromAFolderOfYourOwn() {
        #expect(
            PreviewView.openingFolder(environment: ["XDG_RUNTIME_DIR": "/run/user/1000", "HOME": "/home/u"])?.path
                == "/run/user/1000/net.reqly.Reqly/images")
        #expect(
            PreviewView.openingFolder(environment: ["XDG_CACHE_HOME": "/home/u/.cache", "HOME": "/home/u"])?.path
                == "/home/u/.cache/reqly/images")
        #expect(
            PreviewView.openingFolder(environment: ["XDG_RUNTIME_DIR": "run", "HOME": "/home/u"])?.path
                == "/home/u/.cache/reqly/images")
        #expect(PreviewView.openingFolder(environment: [:]) == nil)
    }

    /// The pictures written to open in an earlier run go as Reqly starts, files and folders, but
    /// not the folder they're in.
    @Test func clearsThePicturesOpenedBefore() throws {
        let files = FileManager.default
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "reqly-opened-\(UUID().uuidString)")
        try files.createDirectory(at: folder.appending(path: "a1b2c3"), withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appending(path: "a1b2c3/map.png"))
        try Data([2]).write(to: folder.appending(path: "image.png"))
        PreviewView.removeAll(in: folder)
        #expect(try files.contentsOfDirectory(atPath: folder.path).isEmpty)
        try files.removeItem(at: folder)
    }

    /// The same picture, opened again, has the same file rather than another copy; another picture
    /// with the same name has a file of its own, and the first keeps its bytes.
    @Test func opensTheSamePictureFromOneFile() throws {
        let files = FileManager.default
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "reqly-opened-\(UUID().uuidString)")
        defer { try? files.removeItem(at: folder) }
        let map = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let first = try PreviewView.write(map, named: "image.png", in: folder)
        let again = try PreviewView.write(map, named: "image.png", in: folder)
        let other = try PreviewView.write(Data([0x89, 0x50, 0x4E, 0x47, 4, 5, 6]), named: "image.png", in: folder)
        #expect(first == again)
        #expect(other != first && other.lastPathComponent == "image.png")
        #expect(try Data(contentsOf: first) == map)
        #expect(try files.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    @Test func countsBytesExactly() {
        #expect(BodyWords.bytes(1) == "1 byte")
        #expect(BodyWords.bytes(12_871, locale: Self.english) == "12,871 bytes")
        #expect(BodyWords.selected(16..<48, locale: Self.english) == "32 bytes selected at offset 16")
    }
}
