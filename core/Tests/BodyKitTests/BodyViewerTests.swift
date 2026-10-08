import BodyKit
import Foundation
import Testing

@Suite struct BodyKindTests {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

    @Test func trustsAClearContentType() {
        #expect(BodyKind.detect(Data("{}".utf8), contentType: "application/json; charset=utf-8") == .json)
        #expect(BodyKind.detect(Data("{}".utf8), contentType: "application/problem+json") == .json)
        #expect(BodyKind.detect(Data("a=1".utf8), contentType: "application/x-www-form-urlencoded") == .form)
        #expect(
            BodyKind.detect(Data(), contentType: "multipart/form-data; boundary=\"XyZ\"") == .multipart(boundary: "XyZ")
        )
        #expect(BodyKind.detect(Data("<p>".utf8), contentType: "text/html") == .html)
        #expect(BodyKind.detect(Data("<a/>".utf8), contentType: "application/atom+xml") == .xml)
        #expect(BodyKind.detect(Data("body {}".utf8), contentType: "text/css") == .text)
        #expect(BodyKind.detect(Data("<svg/>".utf8), contentType: "image/svg+xml") == .image(.svg))
    }

    @Test func looksAtTheBytesWhenTheTypeIsVague() {
        #expect(BodyKind.detect(png, contentType: "application/octet-stream") == .image(.png))
        #expect(BodyKind.detect(png, contentType: nil) == .image(.png))
        #expect(BodyKind.detect(Data(" [1, 2] \n".utf8), contentType: "text/plain") == .json)
        #expect(BodyKind.detect(Data("<!DOCTYPE html><html></html>".utf8), contentType: nil) == .html)
        #expect(BodyKind.detect(Data("<?xml version=\"1.0\"?><a/>".utf8), contentType: nil) == .xml)
        #expect(BodyKind.detect(Data("just words".utf8), contentType: nil) == .text)
        #expect(BodyKind.detect(Data([0x00, 0x01, 0xFF, 0x10]), contentType: nil) == .binary)
        #expect(BodyKind.detect(Data([0x00, 0x01]), contentType: "image/x-unknown") == .binary)
    }

    @Test func decodesTextInItsCharset() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
        #expect(BodyText.decode(latin1, contentType: "text/plain; charset=ISO-8859-1") == "café")
        #expect(BodyText.decode(Data("café".utf8), contentType: "text/plain") == "café")
        #expect(BodyText.decode(latin1, contentType: nil) == nil)
        #expect(BodyText.decode(Data([0x61, 0x00, 0x62]), contentType: nil) == nil)
    }
}

@Suite struct JSONTests {
    let forecast = """
        {"city":"Amsterdam","updated":"2026-09-30T10:42:07Z","units":"metric",\
        "current":{"temperature":14.2,"feelsLike":12.8,"condition":"light-rain","humidity":0.82,\
        "wind":{"speed":5.4,"direction":"SW"}},"hourly":[{"time":"11:00","temperature":14.6,"rain":0.4},\
        {"time":"12:00","temperature":15.1,"rain":0.1},{"time":"13:00","temperature":15.8,"rain":0}],\
        "alerts":[],"stale":false}
        """

    @Test func formatsLikeTheDesign() throws {
        let formatted = try JSONValue.parse(Data(forecast.utf8)).formatted()
        #expect(
            formatted.text == """
                {
                  "city": "Amsterdam",
                  "updated": "2026-09-30T10:42:07Z",
                  "units": "metric",
                  "current": {
                    "temperature": 14.2,
                    "feelsLike": 12.8,
                    "condition": "light-rain",
                    "humidity": 0.82,
                    "wind": { "speed": 5.4, "direction": "SW" }
                  },
                  "hourly": [
                    { "time": "11:00", "temperature": 14.6, "rain": 0.4 },
                    { "time": "12:00", "temperature": 15.1, "rain": 0.1 },
                    { "time": "13:00", "temperature": 15.8, "rain": 0 }
                  ],
                  "alerts": [],
                  "stale": false
                }
                """)
        let text = formatted.text as NSString
        func kind(of word: String) -> SyntaxKind? {
            let range = text.range(of: word)
            return formatted.tokens.first { $0.location == range.location && $0.length == range.length }?.kind
        }
        #expect(kind(of: "\"city\"") == .key)
        #expect(kind(of: "\"Amsterdam\"") == .string)
        #expect(kind(of: "14.2") == .number)
        #expect(kind(of: "false") == .literal)
    }

    @Test func keepsNumbersAndKeyOrderAsSent() throws {
        let value = try JSONValue.parse(Data(#"{"b": 1.50, "a": 2e10, "c": -0}"#.utf8))
        #expect(
            value
                == .object([
                    JSONMember(key: "b", value: .number("1.50")), JSONMember(key: "a", value: .number("2e10")),
                    JSONMember(key: "c", value: .number("-0")),
                ]))
    }

    @Test func unescapesStrings() throws {
        let value = try JSONValue.parse(Data(#"["café", "😀", "line\nbreak", "q\"uote"]"#.utf8))
        #expect(value == .array([.string("café"), .string("😀"), .string("line\nbreak"), .string("q\"uote")]))
        #expect(value.formatted().text == #"["café", "😀", "line\nbreak", "q\"uote"]"#)
    }

    @Test func rejectsWhatIsNotJSON() {
        for text in ["", "{", "[1,]", "{\"a\" 1}", "tru", "01x", "\"open", "[1] 2", "{'a': 1}"] {
            #expect(throws: JSONError.self) { try JSONValue.parse(Data(text.utf8)) }
        }
        // Too deep to be real, deep enough to exhaust a stack.
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        #expect(throws: JSONError.self) { try JSONValue.parse(Data(deep.utf8)) }
    }

    @Test func handlesTheDeepestJSONItAccepts() throws {
        let depth = JSONValue.maximumDepth
        let deepest = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        let value = try JSONValue.parse(Data(deepest.utf8))
        #expect(value.formatted().text.contains("1"))
        #expect(JSONTree(value, rootLabel: "Response").nodes.count == depth + 1)
        let tooDeep = "[" + deepest + "]"
        #expect(throws: JSONError.self) { try JSONValue.parse(Data(tooDeep.utf8)) }
    }

    @Test func buildsATreeWithPaths() throws {
        let tree = JSONTree(try JSONValue.parse(Data(forecast.utf8)), rootLabel: "Response")
        let root = tree.nodes[0]
        #expect(root.label == "Response")
        #expect(root.summary == "7 keys")
        #expect(root.typeName == "object")

        let current = try #require(root.children.first { tree.nodes[$0].label == "current" })
        let temperature = try #require(tree.nodes[current].children.first { tree.nodes[$0].label == "temperature" })
        #expect(tree.path(to: temperature) == "current.temperature")
        #expect(tree.nodes[temperature].summary == "14.2")
        #expect(tree.nodes[temperature].typeName == "number")
        let wind = try #require(tree.nodes[current].children.last)
        #expect(tree.nodes[wind].summary == "2 keys")

        let hourly = try #require(root.children.first { tree.nodes[$0].label == "hourly" })
        #expect(tree.nodes[hourly].summary == "3 items")
        let firstHour = tree.nodes[hourly].children[0]
        #expect(tree.nodes[firstHour].summary == "time, temperature, rain")
        #expect(tree.path(to: tree.nodes[firstHour].children[0]) == "hourly[0].time")

        let alerts = try #require(root.children.first { tree.nodes[$0].label == "alerts" })
        #expect(tree.nodes[alerts].summary == "empty")

        let odd = JSONTree(try JSONValue.parse(Data(#"{"a b": {"x": 1}}"#.utf8)), rootLabel: "Request")
        #expect(odd.path(to: 2) == #"["a b"].x"#)
    }
}

@Suite struct SyntaxTests {
    func pieces(_ text: String, _ tokens: [SyntaxToken]) -> [String] {
        tokens.map {
            "\($0.kind): " + (text as NSString).substring(with: NSRange(location: $0.location, length: $0.length))
        }
    }

    @Test func marksJSONAsSent() {
        let text = #"{"a": "b", "n": -1.5e3, "t": true, "z": null}"#
        #expect(
            pieces(text, JSONSyntax.tokens(in: text)) == [
                #"key: "a""#, #"string: "b""#, #"key: "n""#, "number: -1.5e3", #"key: "t""#, "literal: true",
                #"key: "z""#, "literal: null",
            ])
    }

    @Test func marksMarkup() {
        let text = #"<div class="x" id=y><!-- note --><img src='a.png'/></div>"#
        #expect(
            pieces(text, MarkupSyntax.tokens(in: text)) == [
                "tag: div", "attribute: class", #"attributeValue: "x""#, "attribute: id", "attributeValue: y",
                "comment: <!-- note -->", "tag: img", "attribute: src", "attributeValue: 'a.png'", "tag: div",
            ])
    }

    @Test func leavesScriptsAlone() {
        let text = "<script>if (a <b) {}</script><p>"
        #expect(pieces(text, MarkupSyntax.tokens(in: text)) == ["tag: script", "tag: script", "tag: p"])
    }

    @Test func laysXMLOutOnePerLine() {
        let formatted = MarkupSyntax.formattedXML("<a><b>1</b><c/></a>")
        #expect(formatted.contains("\n"))
        #expect(formatted.contains("<b>1</b>"))
        #expect(MarkupSyntax.formattedXML("<not closed") == "<not closed")
        #expect(MarkupSyntax.formattedXML("<a><b></a>") == "<a><b></a>")
        #expect(MarkupSyntax.formattedXML("<a>") == "<a>")
        #expect(MarkupSyntax.formattedXML("plain text") == "plain text")
    }
}

@Suite struct FormTests {
    @Test func readsURLEncodedForms() {
        #expect(
            URLEncodedForm.fields("city=Amsterdam&q=light+rain&emoji=%F0%9F%98%80&flag") == [
                FormField(name: "city", value: "Amsterdam"), FormField(name: "q", value: "light rain"),
                FormField(name: "emoji", value: "😀"), FormField(name: "flag", value: ""),
            ])
    }

    @Test func readsMultipartForms() {
        var body = Data("--XyZ\r\nContent-Disposition: form-data; name=\"city\"\r\n\r\nAmsterdam\r\n".utf8)
        body += Data("--XyZ\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"rain.png\"\r\n".utf8)
        body +=
            Data("Content-Type: image/png\r\n\r\n".utf8) + Data([0x89, 0x50, 0x0D, 0x0A]) + Data("\r\n--XyZ--\r\n".utf8)

        let parts = MultipartForm.parts(body, boundary: "XyZ")
        #expect(parts.count == 2)
        #expect(parts[0].name == "city")
        #expect(parts[0].body == Data("Amsterdam".utf8))
        #expect(parts[1].name == "photo")
        #expect(parts[1].filename == "rain.png")
        #expect(parts[1].contentType == "image/png")
        #expect(parts[1].body == Data([0x89, 0x50, 0x0D, 0x0A]))
    }

    @Test func laysBytesOutInRows() {
        let data = Data("Hello, Reqly! 0123456789".utf8)
        #expect(HexDump.rowCount(forSize: data.count) == 2)
        #expect(HexDump.rowCount(forSize: 0) == 0)
        let first = HexDump.row(0, of: data)
        #expect(first.offset == "00000000")
        #expect(first.hex == "48 65 6C 6C 6F 2C 20 52  65 71 6C 79 21 20 30 31")
        #expect(first.text == "Hello, Reqly! 01")
        let second = HexDump.row(1, of: data)
        #expect(second.offset == "00000010")
        #expect(second.hex == "32 33 34 35 36 37 38 39")
        #expect(second.text == "23456789")
        #expect(HexDump.row(0, of: Data([0x00, 0x7F, 0x41])).text == "..A")
    }
}

@Suite struct JavaScriptSyntaxTests {
    func pieces(_ text: String) -> [String: [String]] {
        let units = Array(text.utf16)
        var found: [String: [String]] = [:]
        for token in JavaScriptSyntax.tokens(in: text) {
            let piece = String(decoding: units[token.location..<token.location + token.length], as: UTF16.self)
            found["\(token.kind)", default: []].append(piece)
        }
        return found
    }

    @Test func marksScripts() {
        let found = pieces(
            """
            // Adds a token.
            async function onRequest(request) {
              const token = shared.token ?? "none"; /* a comment
              over two lines */
              request.headers.set('X-Count', `n=${1 + 2}`);
              if (request.json?.default === null) return respond(503, "down");
            }
            """)
        #expect(found["comment"] == ["// Adds a token.", "/* a comment\n  over two lines */"])
        #expect(found["keyword"] == ["async", "function", "const", "if", "return"])
        #expect(found["string"] == [#""none""#, "'X-Count'", "`n=${1 + 2}`", #""down""#])
        #expect(found["number"] == ["503"])
        #expect(found["literal"] == ["null"])
    }

    @Test func keepsGoingPastWhatsUnfinished() {
        #expect(pieces("const a = \"no end\nconst b = 1")["keyword"] == ["const", "const"])
        #expect(pieces("/* never closed")["comment"] == ["/* never closed"])
    }
}
