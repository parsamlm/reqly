import BodyKit
import Foundation
import Presentation

/// A body's text as a GTK text view shows it: all of it, or the start of a long one, with the
/// core's syntax tokens as runs of color. The core counts its tokens in UTF-16 code units, as
/// AppKit does; GTK's text buffers count characters, Unicode scalars, so each token is placed
/// again. None of it needs a window, and it's worked out away from it.
struct CodeText: Sendable, Equatable {
    /// The colors code takes, as the Mac has them. Text without a token is punctuation, in code,
    /// and the text's own color in plain text.
    enum Color: Sendable, Hashable, CaseIterable {
        case key, string, number, literal, comment

        /// The color a token's kind takes, as on the Mac: keywords and literals share one, as
        /// Xcode has them, and a tag's name takes a number's.
        init(_ kind: SyntaxKind) {
            switch kind {
            case .key: self = .key
            case .string, .attributeValue: self = .string
            case .number, .tag: self = .number
            case .literal, .attribute, .keyword: self = .literal
            case .comment: self = .comment
            }
        }
    }

    /// A stretch of the text in one color, from `start` to `end` in characters.
    struct Run: Sendable, Equatable {
        var color: Color
        var start: Int
        var end: Int
    }

    /// The page shows up to this many lines of a body, or this many bytes, and the rest in a view
    /// of its own: a page's text view lays out every line it holds, since it shows them all. As
    /// the speed part measured them, 5,000 lines of code and a line of 256 KB keep the window's
    /// longest wait within the Mac's 70 ms, and 6,800 lines or a line of 512 KB go past it.
    static let lineLimit = 5_000
    static let byteLimit = 256 << 10
    /// A line longer than this, in characters, stays uncolored. A GTK text buffer splits a line's
    /// text at each change of color, and looks through the whole line again each time, and lays
    /// the line out again with every color, so a long line of many tokens, such as JSON sent on
    /// one line, keeps the window waiting: one of 9,500 characters, half a second.
    static let longLine = 2_000
    /// Show Whole Body shows a line longer than this, in characters, in pieces this long.
    static let longestLine = 10_000

    /// What the view shows: the text, or its start, with any NUL character as U+FFFD, which a
    /// text buffer can't hold.
    var text: String
    var runs: [Run]
    /// Whether it's code, which keeps its lines whole, or plain text, which wraps.
    var isCode: Bool
    /// How many lines the whole text has, and how many of them show.
    var lines: Int
    var shownLines: Int
    /// The whole text's size in UTF-8, and how much of it shows.
    var bytes: Int
    var shownBytes: Int

    /// Whether only the start of the text shows.
    var isCut: Bool { shownBytes < bytes }
    /// Whether lines longer than the pieces asked for were split into them.
    var isSplit = false

    /// Whether the view wraps its lines: plain text does, and code split into pieces, which reads
    /// better wrapped than in pieces side by side.
    var wraps: Bool { !isCode || isSplit }

    /// `code`'s text, up to `lineLimit` lines or `byteLimit` bytes, ending at a line's end where
    /// it can, with its tokens' colors on lines up to `longLine` characters.
    /// With `pieces`, a line longer than that many characters shows in pieces of that many, each
    /// on a line of its own: GTK lays a line out whole, and one of megabytes would take seconds.
    init(
        _ code: BodyPresentation.Code, lineLimit: Int = Self.lineLimit, byteLimit: Int = Self.byteLimit,
        pieces: Int? = nil
    ) {
        self.init(
            text: code.text, tokens: code.tokens, isCode: code.isCode, lineLimit: lineLimit, byteLimit: byteLimit,
            pieces: pieces)
    }

    init(
        text whole: String, tokens: [SyntaxToken], isCode: Bool, lineLimit: Int = Self.lineLimit,
        byteLimit: Int = Self.byteLimit, longLine: Int = Self.longLine, pieces: Int? = nil
    ) {
        self.isCode = isCode
        var whole = whole
        let (cut, lines, shownLines) = whole.withUTF8 { Self.cut($0, lineLimit: lineLimit, byteLimit: byteLimit) }
        self.lines = lines
        self.shownLines = shownLines
        bytes = whole.utf8.count
        shownBytes = cut
        var shown =
            cut < bytes
            ? whole.withUTF8 { String(decoding: UnsafeBufferPointer(rebasing: $0[..<cut]), as: UTF8.self) } : whole
        runs = Self.runs(of: tokens, in: shown, longLine: longLine)
        if shown.utf8.contains(0) {
            shown = shown.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}")
        }
        // Only uncolored lines are long enough to split, so each run moves on whole.
        if let pieces, pieces >= longLine {
            let (split, breaks) = Self.split(shown, every: pieces)
            if !breaks.isEmpty {
                shown = split
                isSplit = true
                var before = 0
                for index in runs.indices {
                    while before < breaks.count, breaks[before] <= runs[index].start {
                        before += 1
                    }
                    runs[index].start += before
                    runs[index].end += before
                }
            }
        }
        text = shown
    }

    /// `text` with a line break after every `piece` characters of a line longer than that, and
    /// where each break went in, in the characters of `text`.
    static func split(_ text: String, every piece: Int) -> (text: String, breaks: [Int]) {
        var breaks: [Int] = []
        var split: [UInt8] = []
        split.reserveCapacity(text.utf8.count + text.utf8.count / max(1, piece) + 1)
        var character = 0
        var lineLength = 0
        for byte in text.utf8 {
            // A character starts on any byte that doesn't continue one.
            if byte & 0xC0 != 0x80 {
                if byte == 0x0A {
                    lineLength = 0
                } else {
                    if lineLength == piece {
                        split.append(0x0A)
                        breaks.append(character)
                        lineLength = 0
                    }
                    lineLength += 1
                }
                character += 1
            }
            split.append(byte)
        }
        return (String(decoding: split, as: UTF8.self), breaks)
    }

    /// Where to cut `utf8` to show at most `lineLimit` lines and `byteLimit` bytes: after a whole
    /// line where there's one, without its line break, or else on a character's boundary. Gives
    /// the bytes to show, the text's lines and the lines shown.
    private static func cut(
        _ utf8: UnsafeBufferPointer<UInt8>, lineLimit: Int, byteLimit: Int
    ) -> (bytes: Int, lines: Int, shownLines: Int) {
        var lines = 1
        var cut: Int?
        var shownLines = 1
        // The last line break that fits in the byte limit.
        var lastBreak: Int?
        for position in utf8.indices where utf8[position] == 0x0A {
            if cut == nil {
                if position > byteLimit {
                    cut = lastBreak ?? boundary(utf8, before: byteLimit)
                } else if lines == lineLimit {
                    cut = position
                } else {
                    lastBreak = position
                    shownLines += 1
                }
            }
            lines += 1
        }
        if cut == nil, utf8.count > byteLimit {
            cut = lastBreak ?? boundary(utf8, before: byteLimit)
        }
        guard let cut else { return (utf8.count, lines, lines) }
        if cut == lastBreak, cut < utf8.count {
            // The line after the last break was cut off: it doesn't show.
            shownLines -= 1
        }
        return (cut, lines, max(1, shownLines))
    }

    /// `limit`, or the closest character boundary before it.
    private static func boundary(_ utf8: UnsafeBufferPointer<UInt8>, before limit: Int) -> Int {
        var position = min(limit, utf8.count)
        while position > 0, position < utf8.count, utf8[position] & 0xC0 == 0x80 {
            position -= 1
        }
        return position
    }

    /// The tokens' colors in `text`, in characters, leaving out tokens past its end and those on
    /// lines longer than `longLine`. The tokens' places are UTF-16 offsets into a text that
    /// `text` starts.
    static func runs(of tokens: [SyntaxToken], in text: String, longLine: Int = Self.longLine) -> [Run] {
        let limit = text.utf16.count
        // Every place a token starts or ends, in order, so one pass over the text finds them all.
        var places: [Int] = []
        places.reserveCapacity(tokens.count * 2)
        for token in tokens where token.length > 0 && token.location < limit {
            places.append(token.location)
            places.append(min(token.location + token.length, limit))
        }
        guard !places.isEmpty else { return [] }
        places.sort()
        var characters = [Int](repeating: 0, count: places.count)
        var lineOf = [Int](repeating: 0, count: places.count)
        var lineLengths: [Int] = []
        var unit = 0
        var character = 0
        var line = 0
        var lineLength = 0
        var next = 0
        for scalar in text.unicodeScalars {
            let width = UTF16.width(scalar)
            // A place inside a surrogate pair counts as the character's own.
            while next < places.count, places[next] < unit + width {
                characters[next] = character
                lineOf[next] = line
                next += 1
            }
            unit += width
            character += 1
            if scalar == "\n" {
                lineLengths.append(lineLength)
                lineLength = 0
                line += 1
            } else {
                lineLength += 1
            }
        }
        while next < places.count {
            characters[next] = character
            lineOf[next] = line
            next += 1
        }
        lineLengths.append(lineLength)

        func index(of place: Int) -> Int {
            var low = 0
            var high = places.count
            while low < high {
                let middle = (low + high) / 2
                if places[middle] < place {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }
        var runs: [Run] = []
        runs.reserveCapacity(tokens.count)
        for token in tokens where token.length > 0 && token.location < limit {
            let start = index(of: token.location)
            let end = index(of: min(token.location + token.length, limit))
            guard lineLengths[lineOf[start]] <= longLine, lineLengths[lineOf[end]] <= longLine,
                characters[start] < characters[end]
            else { continue }
            runs.append(Run(color: Color(token.kind), start: characters[start], end: characters[end]))
        }
        return runs
    }
}
