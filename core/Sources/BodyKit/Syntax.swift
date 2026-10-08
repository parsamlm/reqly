import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// What a stretch of code is, for coloring it.
public enum SyntaxKind: Hashable, Sendable {
    /// An object's key in JSON.
    case key
    case string
    case number
    /// `true`, `false` or `null`.
    case literal
    /// A word of the language, such as `function` or `return` in JavaScript.
    case keyword
    /// An element's name in XML or HTML.
    case tag
    case attribute
    case attributeValue
    case comment
}

/// A stretch of text to color, in UTF-16 code units, as `NSAttributedString` counts them.
public struct SyntaxToken: Hashable, Sendable {
    public var kind: SyntaxKind
    public var location: Int
    public var length: Int

    public init(kind: SyntaxKind, location: Int, length: Int) {
        self.kind = kind
        self.location = location
        self.length = length
    }
}

/// Text with its syntax marked. Anything without a token is punctuation or plain text.
public struct HighlightedText: Hashable, Sendable {
    public var text: String
    public var tokens: [SyntaxToken]

    public init(text: String, tokens: [SyntaxToken]) {
        self.text = text
        self.tokens = tokens
    }

    /// Bodies longer than this aren't colored, since that would take too long.
    public static let highlightLimit = 1 << 20
}

/// Builds text and its tokens together.
struct TextBuilder {
    private var text = ""
    private var length = 0
    private var tokens: [SyntaxToken] = []

    mutating func append(_ piece: String, _ kind: SyntaxKind? = nil) {
        let count = piece.utf16.count
        if let kind {
            tokens.append(SyntaxToken(kind: kind, location: length, length: count))
        }
        text += piece
        length += count
    }

    var result: HighlightedText {
        HighlightedText(text: text, tokens: tokens)
    }
}

/// Marks the syntax of JSON text as it was sent, even when it isn't quite valid.
public enum JSONSyntax {
    public static func tokens(in text: String) -> [SyntaxToken] {
        let units = Array(text.utf16)
        var tokens: [SyntaxToken] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == quote {
                let start = index
                index += 1
                while index < units.count {
                    if units[index] == backslash {
                        index += 2
                        continue
                    }
                    index += 1
                    if units[index - 1] == quote { break }
                }
                index = min(index, units.count)
                // A string followed by a colon is a key.
                var next = index
                while next < units.count, isWhitespace(units[next]) {
                    next += 1
                }
                let kind: SyntaxKind = next < units.count && units[next] == colon ? .key : .string
                tokens.append(SyntaxToken(kind: kind, location: start, length: index - start))
            } else if unit == minus || isDigit(unit) {
                let start = index
                index += 1
                while index < units.count, isDigit(units[index]) || numberPunctuation.contains(units[index]) {
                    index += 1
                }
                tokens.append(SyntaxToken(kind: .number, location: start, length: index - start))
            } else if isLetter(unit) {
                let start = index
                while index < units.count, isLetter(units[index]) {
                    index += 1
                }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if word == "true" || word == "false" || word == "null" {
                    tokens.append(SyntaxToken(kind: .literal, location: start, length: index - start))
                }
            } else {
                index += 1
            }
        }
        return tokens
    }
}

/// Marks the syntax of JavaScript: keywords, strings, numbers, literals and comments. A
/// template literal is one string, including what's inside its `${}`.
public enum JavaScriptSyntax {
    private static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do",
        "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof", "let",
        "new", "of", "return", "static", "super", "switch", "this", "throw", "try", "typeof", "var", "void",
        "while", "yield",
    ]
    private static let literals: Set<String> = ["true", "false", "null", "undefined", "NaN", "Infinity"]

    public static func tokens(in text: String) -> [SyntaxToken] {
        let units = Array(text.utf16)
        var tokens: [SyntaxToken] = []
        var index = 0
        let slash = UInt16(UInt8(ascii: "/"))
        let star = UInt16(UInt8(ascii: "*"))
        let quotes: Set<UInt16> = Set("\"'`".utf16)
        func isWordUnit(_ unit: UInt16) -> Bool {
            isLetter(unit) || isDigit(unit) || unit == UInt16(UInt8(ascii: "_")) || unit == UInt16(UInt8(ascii: "$"))
        }
        while index < units.count {
            let unit = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            if unit == slash, next == slash {
                let start = index
                while index < units.count, units[index] != 0x0A { index += 1 }
                tokens.append(SyntaxToken(kind: .comment, location: start, length: index - start))
            } else if unit == slash, next == star {
                let start = index
                index += 2
                while index + 1 < units.count, !(units[index] == star && units[index + 1] == slash) {
                    index += 1
                }
                index = min(index + 2, units.count)
                tokens.append(SyntaxToken(kind: .comment, location: start, length: index - start))
            } else if quotes.contains(unit) {
                let start = index
                index += 1
                while index < units.count {
                    if units[index] == backslash {
                        index += 2
                        continue
                    }
                    // A quote's string ends at the line's end, a template's only at its backtick.
                    if units[index] == 0x0A, unit != UInt16(UInt8(ascii: "`")) { break }
                    index += 1
                    if units[index - 1] == unit { break }
                }
                index = min(index, units.count)
                tokens.append(SyntaxToken(kind: .string, location: start, length: index - start))
            } else if isDigit(unit) {
                let start = index
                while index < units.count, isWordUnit(units[index]) || units[index] == UInt16(UInt8(ascii: ".")) {
                    index += 1
                }
                tokens.append(SyntaxToken(kind: .number, location: start, length: index - start))
            } else if isWordUnit(unit) {
                let start = index
                while index < units.count, isWordUnit(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                // A word after a dot is a property, even when it's spelled like a keyword.
                let isProperty = start > 0 && units[start - 1] == UInt16(UInt8(ascii: "."))
                if !isProperty, keywords.contains(word) {
                    tokens.append(SyntaxToken(kind: .keyword, location: start, length: index - start))
                } else if !isProperty, literals.contains(word) {
                    tokens.append(SyntaxToken(kind: .literal, location: start, length: index - start))
                }
            } else {
                index += 1
            }
        }
        return tokens
    }
}

/// Marks the syntax of XML and HTML: element names, attributes and their values, and comments.
public enum MarkupSyntax {
    public static func tokens(in text: String) -> [SyntaxToken] {
        let units = Array(text.utf16)
        var tokens: [SyntaxToken] = []
        var index = 0
        func starts(with prefix: String, at position: Int) -> Bool {
            let expected = Array(prefix.utf16)
            return position + expected.count <= units.count
                && units[position..<position + expected.count].elementsEqual(expected)
        }
        /// Whether `name` comes next, in any case. Running out of text counts as finding it.
        func nameFollows(_ name: String, at position: Int) -> Bool {
            let expected = Array(name.utf16)
            guard position + expected.count <= units.count else { return true }
            return String(decoding: units[position..<position + expected.count], as: UTF16.self).lowercased() == name
        }
        func skip(to marker: String) {
            while index < units.count, !starts(with: marker, at: index) {
                index += 1
            }
            index = min(index + marker.utf16.count, units.count)
        }
        while index < units.count {
            guard units[index] == lessThan else {
                index += 1
                continue
            }
            let start = index
            if starts(with: "<!--", at: index) {
                skip(to: "-->")
                tokens.append(SyntaxToken(kind: .comment, location: start, length: index - start))
                continue
            }
            if starts(with: "<![CDATA[", at: index) {
                skip(to: "]]>")
                tokens.append(SyntaxToken(kind: .string, location: start, length: index - start))
                continue
            }
            index += 1
            let isClosing = index < units.count && units[index] == slash
            if index < units.count, [slash, question, exclamation].contains(units[index]) {
                index += 1
            }
            let nameStart = index
            while index < units.count, isNameUnit(units[index]) {
                index += 1
            }
            let name = String(decoding: units[nameStart..<index], as: UTF16.self).lowercased()
            if index > nameStart {
                tokens.append(SyntaxToken(kind: .tag, location: nameStart, length: index - nameStart))
            }
            while index < units.count, units[index] != greaterThan {
                let unit = units[index]
                guard isNameUnit(unit) else {
                    index += 1
                    continue
                }
                let attributeStart = index
                while index < units.count, isNameUnit(units[index]) {
                    index += 1
                }
                tokens.append(SyntaxToken(kind: .attribute, location: attributeStart, length: index - attributeStart))
                while index < units.count, isWhitespace(units[index]) {
                    index += 1
                }
                guard index < units.count, units[index] == equals else { continue }
                index += 1
                while index < units.count, isWhitespace(units[index]) {
                    index += 1
                }
                let valueStart = index
                if index < units.count, units[index] == quote || units[index] == apostrophe {
                    let delimiter = units[index]
                    index += 1
                    while index < units.count, units[index] != delimiter {
                        index += 1
                    }
                    index = min(index + 1, units.count)
                } else {
                    while index < units.count, !isWhitespace(units[index]), units[index] != greaterThan {
                        index += 1
                    }
                }
                tokens.append(SyntaxToken(kind: .attributeValue, location: valueStart, length: index - valueStart))
            }
            index = min(index + 1, units.count)
            // A script or style holds code, not markup, until its end tag.
            if !isClosing, name == "script" || name == "style" {
                while index < units.count, !starts(with: "</", at: index) || !nameFollows(name, at: index + 2) {
                    index += 1
                }
            }
        }
        return tokens
    }

    /// XML laid out with one element per line. Text that isn't well-formed XML comes back as it was.
    public static func formattedXML(_ text: String) -> String {
        guard isWellFormedXML(text),
            let document = try? XMLDocument(xmlString: text, options: [.nodePreserveWhitespace])
        else {
            return text
        }
        return document.xmlString(options: [.nodePrettyPrint])
    }

    /// Whether `text` is well-formed XML. On Linux, XMLDocument repairs broken XML rather than
    /// refusing it, and XMLParser carries on past some mistakes and misses an element that's never
    /// closed, so this checks the parser's error and that every element it opened was closed.
    static func isWellFormedXML(_ text: String) -> Bool {
        let parser = XMLParser(data: Data(text.utf8))
        let elements = ElementBalance()
        parser.delegate = elements
        return parser.parse() && parser.parserError == nil && elements.isBalanced
    }
}

/// Counts the elements an XML parser opens and closes.
private final class ElementBalance: NSObject, XMLParserDelegate {
    private var depth = 0
    private var sawElement = false

    /// Whether there was an element, and every element was closed.
    var isBalanced: Bool { sawElement && depth == 0 }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        sawElement = true
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        depth -= 1
    }
}

private let quote = UInt16(UInt8(ascii: "\""))
private let apostrophe = UInt16(UInt8(ascii: "'"))
private let backslash = UInt16(UInt8(ascii: "\\"))
private let colon = UInt16(UInt8(ascii: ":"))
private let minus = UInt16(UInt8(ascii: "-"))
private let lessThan = UInt16(UInt8(ascii: "<"))
private let greaterThan = UInt16(UInt8(ascii: ">"))
private let slash = UInt16(UInt8(ascii: "/"))
private let question = UInt16(UInt8(ascii: "?"))
private let exclamation = UInt16(UInt8(ascii: "!"))
private let equals = UInt16(UInt8(ascii: "="))
private let numberPunctuation: Set<UInt16> = Set(".eE+-".utf16)

private func isWhitespace(_ unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09
}

private func isDigit(_ unit: UInt16) -> Bool {
    (0x30...0x39).contains(unit)
}

private func isLetter(_ unit: UInt16) -> Bool {
    (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
}

/// Letters, digits and the punctuation XML allows in names, plus anything outside ASCII.
private func isNameUnit(_ unit: UInt16) -> Bool {
    isLetter(unit) || isDigit(unit) || unit == UInt16(UInt8(ascii: "-")) || unit == UInt16(UInt8(ascii: "_"))
        || unit == colon || unit == UInt16(UInt8(ascii: ".")) || unit > 0x7F
}
