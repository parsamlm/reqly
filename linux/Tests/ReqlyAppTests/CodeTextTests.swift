import BodyKit
import Foundation
import Presentation
import Testing

@testable import ReqlyApp

@Suite struct CodeTextTests {
    /// The characters a run covers, as a GTK text buffer counts them.
    static func words(_ run: CodeText.Run, in text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var words = String.UnicodeScalarView()
        words.append(contentsOf: scalars[run.start..<run.end])
        return String(words)
    }

    @Test func placesTokensInCharactersRatherThanUTF16() {
        // An emoji takes two UTF-16 code units and one character; Persian letters one of each.
        let text = #"{"😀":"باران","k":[1,true]}"#
        let code = CodeText(text: text, tokens: JSONSyntax.tokens(in: text), isCode: true)
        let found = code.runs.map { ($0.color, Self.words($0, in: code.text)) }
        #expect(found.map(\.1) == [#""😀""#, #""باران""#, #""k""#, "1", "true"])
        #expect(found.map(\.0) == [.key, .string, .key, .number, .literal])
        #expect(code.runs.first?.start == 1)
        // After the emoji, a character comes one place earlier than its UTF-16 offset.
        let utf16 = JSONSyntax.tokens(in: text)[1].location
        #expect(code.runs[1].start == utf16 - 1)
    }

    @Test func coversTokensOverManyLinesAndInXML() {
        let text = "<forecast city=\"Tehran\">\n  <!-- two\n  lines -->\n</forecast>"
        let code = CodeText(text: text, tokens: MarkupSyntax.tokens(in: text), isCode: true)
        let found = code.runs.map { Self.words($0, in: code.text) }
        #expect(found.contains("forecast"))
        #expect(found.contains("\"Tehran\""))
        #expect(found.contains("<!-- two\n  lines -->"))
        #expect(code.runs.contains { $0.color == .comment })
    }

    @Test func leavesLongLinesUncolored() {
        let text = #"{"a":1}"# + "\n" + #"{"bbbbbbbbbb":2}"#
        let code = CodeText(text: text, tokens: JSONSyntax.tokens(in: text), isCode: true, longLine: 10)
        #expect(code.runs.map { Self.words($0, in: code.text) } == [#""a""#, "1"])
    }

    @Test func showsTheStartOfALongText() {
        let lines = (1...20).map { "line \($0)" }
        let byLines = CodeText(text: lines.joined(separator: "\n"), tokens: [], isCode: true, lineLimit: 5)
        #expect(byLines.text == lines.prefix(5).joined(separator: "\n"))
        #expect(byLines.isCut && byLines.shownLines == 5 && byLines.lines == 20)

        // Cut at the last whole line that fits.
        let byBytes = CodeText(text: lines.joined(separator: "\n"), tokens: [], isCode: false, byteLimit: 19)
        #expect(byBytes.text == "line 1\nline 2")
        #expect(byBytes.isCut && byBytes.shownLines == 2 && byBytes.shownBytes == 13)

        // One long line: cut on a character's boundary, never inside one.
        let persian = String(repeating: "ب", count: 100)
        let line = CodeText(text: persian, tokens: [], isCode: false, byteLimit: 51)
        #expect(line.text == String(repeating: "ب", count: 25))
        #expect(line.isCut && line.shownLines == 1 && line.lines == 1 && line.bytes == 200)

        let short = CodeText(text: "a\nb", tokens: [], isCode: true)
        #expect(!short.isCut && short.text == "a\nb" && short.lines == 2 && short.shownLines == 2)
    }

    @Test func keepsTokensWithinWhatShows() {
        let text = "[1,\n2,\n3]"
        let code = CodeText(text: text, tokens: JSONSyntax.tokens(in: text), isCode: true, lineLimit: 2)
        #expect(code.text == "[1,\n2,")
        #expect(code.runs.map { Self.words($0, in: code.text) } == ["1", "2"])
    }

    @Test func splitsLongLinesIntoPieces() {
        let split = CodeText.split(
            String(repeating: "a", count: 25) + "\nbb\n" + String(repeating: "ب", count: 10), every: 10)
        #expect(split.text == "aaaaaaaaaa\naaaaaaaaaa\naaaaa\nbb\n" + String(repeating: "ب", count: 10))
        #expect(split.breaks == [10, 20])

        // Colors on the short lines move on past the breaks before them.
        let text = #"{"k":1}"# + "\n" + String(repeating: "x", count: 25) + "\n" + #"{"z":2}"#
        let code = CodeText(text: text, tokens: JSONSyntax.tokens(in: text), isCode: true, longLine: 10, pieces: 10)
        #expect(code.isSplit && code.wraps)
        #expect(code.text.split(separator: "\n").map(\.count) == [7, 10, 10, 5, 7])
        #expect(code.runs.map { Self.words($0, in: code.text) } == [#""k""#, "1", #""z""#, "2"])
        let whole = CodeText(text: text, tokens: [], isCode: true, longLine: 10)
        #expect(!whole.isSplit && !whole.wraps)
    }

    @Test func holdsNoNULCharacters() {
        let code = CodeText(text: "a\u{0}b", tokens: [], isCode: false)
        #expect(code.text == "a\u{FFFD}b")
        #expect(code.text.unicodeScalars.count == 3)
    }
}

@Suite struct HexLinesTests {
    static let bytes = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n\u{1}".utf8)

    @Test func laysOutSixteenBytesAsTheCoreDoes() {
        let lines = HexLines.count(size: Self.bytes.count, perLine: 16)
        #expect(lines == HexDump.rowCount(forSize: Self.bytes.count))
        for index in 0..<lines - 1 {
            let row = HexDump.row(index, of: Self.bytes)
            let start = index * 16
            let line = HexLines.line(
                at: start, Self.bytes[start..<start + 16], perLine: 16, size: Self.bytes.count)
            #expect(line == "\(row.offset.suffix(6))  \(row.hex)  \(row.text)")
        }
        #expect(
            HexLines.line(at: 0, Self.bytes.prefix(16), perLine: 16, size: Self.bytes.count)
                == "000000  48 54 54 50 2F 31 2E 31  20 32 30 30 20 4F 4B 0D  HTTP/1.1 200 OK.")
    }

    @Test func laysOutEightWhenNarrowAndPadsTheLast() {
        #expect(
            HexLines.line(at: 8, Self.bytes[8..<16], perLine: 8, size: Self.bytes.count)
                == "000008  20 32 30 30 20 4F 4B 0D   200 OK.")
        let last = Self.bytes.count - 1
        let short = HexLines.line(at: last, Self.bytes[last...], perLine: 8, size: Self.bytes.count)
        #expect(short == "00002D  01" + String(repeating: " ", count: 21) + "  .")
        #expect(short.count == HexLines.width(perLine: 8, size: Self.bytes.count) - 7)
        #expect(
            HexLines.line(at: 0, Self.bytes.prefix(16), perLine: 16, size: Self.bytes.count).count
                == HexLines.width(perLine: 16, size: Self.bytes.count))
    }

    @Test func widensTheOffsetPastSixteenMegabytes() {
        #expect(HexLines.offsetDigits(size: 0xFF_FFFF) == 6)
        #expect(HexLines.offsetDigits(size: 0x100_0000) == 8)
        #expect(HexLines.line(at: 0xABCDEF0, [0x41], perLine: 16, size: 0x1000_0000).hasPrefix("0ABCDEF0  41 "))
    }

    @Test func copiesBytesAsHex() {
        #expect(HexLines.hex(Self.bytes.prefix(4)) == "48 54 54 50")
        #expect(HexLines.hex([UInt8]()) == "")
        let all = (0...255).map { UInt8($0) }
        #expect(HexLines.hex(all) == all.map { String(format: "%02X", $0) }.joined(separator: " "))
    }
}

@Suite struct TreeRowsTests {
    static let tree = JSONTree(
        try! JSONValue.parse(
            Data(#"{"city":"Tehran","days":[{"sky":"clear","high":31},{"sky":"rain","high":24}],"note":null}"#.utf8)),
        rootLabel: "Response")

    func label(_ id: Int) -> String { Self.tree.node(id).label }

    @Test func opensTheRootAndItsChildren() {
        let opened = TreeRows.opened(Self.tree)
        #expect(opened.map(label) == ["Response", "days"])
        #expect(TreeRows.opened(Self.tree, most: 2) == [0])
    }

    @Test func keepsMatchesAndTheNodesAboveThem() throws {
        #expect(TreeRows.kept(Self.tree, by: "  ") == nil)
        let rain = try #require(TreeRows.kept(Self.tree, by: "RAIN"))
        #expect(Set(rain.map(label)) == ["Response", "days", "1", "sky"])
        let high = try #require(TreeRows.kept(Self.tree, by: "high"))
        #expect(high.count == 6)
        #expect(TreeRows.children(of: 0, in: Self.tree, kept: high).map(label) == ["days"])
        #expect(TreeRows.children(of: 0, in: Self.tree, kept: nil).map(label) == ["city", "days", "note"])
        // A container's summary, such as "2 items", isn't a value to match.
        #expect(TreeRows.kept(Self.tree, by: "items")?.isEmpty == true)
    }

    @Test func readsARowAsOne() {
        let city = Self.tree.node(Self.tree.node(0).children[0])
        #expect(TreeRows.words(city) == "city, \(city.summary), \(city.typeName)")
    }
}
