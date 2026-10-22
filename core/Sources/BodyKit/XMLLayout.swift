/// Reqly's own XML reader, which checks that XML is well-formed and lays it out as Foundation's
/// XMLDocument does with `.nodePrettyPrint` on the Mac. Reqly uses it everywhere instead of
/// XMLDocument and XMLParser, which crash on some namespace errors and on deep nesting, and slow
/// to a crawl on HTML with many `<br>`s, and on Linux need libxml2.so.2, which Ubuntu 26.04 and
/// Debian 14 no longer have. The Mac's tests check it against XMLDocument.
///
/// It refuses what XML 1.0 and Namespaces in XML refuse, and what else makes XMLDocument refuse a
/// body: what libxml2 counts as a namespace error, such as a namespace that isn't a URI, an ID
/// used twice, some mistakes in a DOCTYPE, and groups nested more than 128 deep in a content
/// model. It never reads an external entity or DTD. An undeclared entity is refused unless the
/// DOCTYPE names an external subset, which could declare it, and then it's left out, as
/// XMLDocument does. A document whose root is `html` is written as HTML, or as XHTML in XHTML's
/// namespace, as XMLDocument writes them.
///
/// Where it differs from XMLDocument on purpose:
/// - It lays out the text as Reqly decoded it, whatever encoding the declaration names.
///   XMLDocument reads the text again in that encoding, which garbles or refuses text in some of
///   them, and refuses names its converter doesn't know. Both refuse UTF-16 and UTF-32, since the
///   text isn't in them by then.
/// - It keeps a U+FEFF that starts a text, an attribute's value or a comment, written as it is or
///   as `&#xFEFF;`. XMLDocument drops it.
/// - It makes each line ending `\n` in CDATA sections and public IDs too, as XML says. XMLDocument
///   keeps their `\r`s.
/// - A tab or `\r` that a character reference in an entity's text stands for stays as it is, as
///   XML says. XMLDocument makes the tab a space in a value, and the `\r` a `\n` in text.
/// - Elements from an entity's text are in the namespaces around its reference, as Namespaces in
///   XML says. XMLDocument reads them in no namespace, and writes `xmlns=""` on them.
/// - It checks an `xml:id` with XML 1.0's fifth edition, as it does names. libxml2 checks it with
///   the fourth edition's letters, and refuses some that came later, such as Glagolitic.
/// - Names, and single values, comments, CDATA sections and instructions, can be any length.
///   libxml2 refuses a name over 50,000 bytes, and the others over 10,000,000.
/// - Lines stop moving right past `deepestIndent` levels, so a line starts with at most 128
///   spaces, and a deeply nested body's layout grows with its size, not with its depth squared.
///   XMLDocument indents every level.
/// - Entities may add up to `expansionLimit` of text between them, nested to any depth. libxml2's
///   limit for entities is its own, and stops sooner when they nest: from 9 levels in a value, 18
///   in text, and 1,024 in the DOCTYPE.
/// - The layout may be at most `layoutLimit` long, and a body whose layout would be longer is
///   refused. XMLDocument writes a layout of any size, which a small body can make huge: with a
///   namespace the DOCTYPE gives every element, or an `<!ATTLIST>` of many attributes, whose
///   element's name it writes once for each.
/// - XMLDocument crashes on an XHTML 1.0 DOCTYPE whose `html` is in another namespace. This lays
///   that out as HTML.
enum XMLLayout {
    /// Lines stop moving right at this depth.
    static let deepestIndent = 32

    /// `text` laid out with one element per line, or nil when it isn't well-formed XML, or its
    /// layout would be too long.
    static func formatted(_ text: String) -> String? {
        guard var reader = XMLReader(text) else { return nil }
        return try? reader.read()
    }
}

private struct Malformed: Error {}

private struct XMLReader {
    /// What's being read: the document, or the text of an entity it refers to.
    var bytes: [UInt8]
    var index = 0
    /// The entities being read in place of their references, innermost last, and their names.
    var expansions: [Expansion] = []
    var expanding: Set<EntityName> = []
    /// How many of `expansions` are parameter entities, so that needn't be counted each time.
    var parameterExpansions = 0
    /// How much entity text has been read in place of references, and how much may be, so a small
    /// body can't expand into a huge one.
    var expanded = 0
    let expansionLimit: Int
    /// How long the layout may get, so a small body can't make a huge one. The DOCTYPE's defaults
    /// count toward it too, written or not, since each element they're given reads them again.
    let layoutLimit: Int
    var defaultsRead = 0

    // The XML declaration.
    var version: [UInt8]?
    var encoding: [UInt8]?
    var standalone: Bool?

    // The DOCTYPE, and what it declares.
    var doctype: [UInt8] = []
    var sawDoctype = false
    var hasExternalSubset = false
    var generalEntities: [[UInt8]: Entity] = [:]
    var parameterEntities: [[UInt8]: Entity] = [:]
    /// The parameter entity the internal subset last referred to, with nothing declared since.
    /// XMLDocument fails on reading it again straight away.
    var lastParameterEntity: [UInt8]?
    var declaredElements: Set<[UInt8]> = []
    /// The attributes declared for each element, which is looked up once per declaration, since its
    /// name can be long.
    var declaredAttributes: [[UInt8]: Set<[UInt8]>] = [:]
    /// The declared types of attributes that aren't CDATA, whose values XML normalizes further, by
    /// element, so a start tag looks its element up once.
    var attributeTypes: [[UInt8]: [[UInt8]: AttributeType]] = [:]
    var elementsWithID: Set<[UInt8]> = []
    /// The attributes the DOCTYPE gives elements by default that matter: libxml2 adds the
    /// namespaces among them, and checks the prefixes of those with prefixes, though XMLDocument
    /// doesn't write them.
    var attributeDefaults: [[UInt8]: [Default]] = [:]
    /// The number of the value of the first default each element has, whatever its name.
    var firstDefaults: [[UInt8]: Int] = [:]
    var doctypeSystemID: [UInt8]?

    // The elements.
    var kind = Kind.xml
    var out: [UInt8] = []
    var open: [OpenElement] = []
    /// The open elements' names, one after another.
    var names: [UInt8] = []
    var sawRoot = false
    /// Text read since the last markup, escaped, and whether it's all whitespace.
    var text: [UInt8] = []
    var textIsBlank = true
    /// The namespaces each prefix is bound to, innermost last, by their URIs' numbers. The default
    /// namespace's prefix is empty.
    var namespaces: [[UInt8]: [Int]] = [:]
    /// A number for each namespace URI, so names can be told apart by namespace without comparing
    /// URIs, which can be long. The `xml` prefix's is 0.
    var uriNumbers: [[UInt8]: Int] = [xmlNamespace: 0]
    /// The prefixes the open elements bound, in order.
    var boundPrefixes: [[UInt8]] = []
    var ids: Set<[UInt8]> = []
    /// Where the `?` that ends each instruction before the root is, in the layout and in the
    /// DOCTYPE, since HTML ends them without it.
    var prologInstructions: [Int] = []
    var doctypeInstructions: [Int] = []
    /// The depth of the void element being read, such as `<br>`, whose content isn't written.
    var voidDepth: Int?
    /// The encoding an XHTML document's `<meta>` names, which XMLDocument writes instead, and
    /// whether the `<meta>` that counts has been read.
    var metaEncoding: [UInt8]?
    var sawContentTypeMeta = false

    // The start tag being read: its name and its attributes' names and values, one after another.
    var tagBytes: [UInt8] = []
    var attributes: [Attribute] = []

    struct EntityName: Hashable {
        var name: [UInt8]
        var isParameter: Bool
    }

    struct Expansion {
        var name: [UInt8]
        var isParameter: Bool
        var isFromParameterEntity: Bool
        var outer: [UInt8]
        var outerIndex: Int
        /// How many elements were open when it started. It must close the ones it opens.
        var depth: Int
    }

    struct Entity {
        enum Kind {
            /// Its replacement text.
            case text([UInt8])
            /// Kept in a file of its own, which isn't read.
            case external
            /// One with an empty system ID and no public ID, which XMLDocument refuses a reference
            /// to.
            case externalWithoutSystemID
            /// Not XML at all, named by a notation.
            case unparsed
        }

        var kind: Kind
        /// Declared in a parameter entity's text, which libxml2 treats a little differently.
        var isFromParameterEntity = false
    }

    /// How XMLDocument writes a document: as XML, or as HTML or XHTML when its root is `html`.
    enum Kind {
        case xml, html, xhtml
    }

    /// An attribute the DOCTYPE gives an element by default.
    struct Default {
        var name: [UInt8]
        var value: [UInt8]
        /// The number of its URI, when it's a namespace.
        var namespace: Int?
    }

    /// An attribute's name in its namespace, which no two attributes may share.
    struct ExpandedName: Hashable {
        var namespace: Int
        var localName: ArraySlice<UInt8>
    }

    enum AttributeType {
        case cdata, id, idref, idrefs, entity, entities, nmtoken, nmtokens, notation, enumeration
    }

    struct OpenElement {
        var nameStart: Int
        var nameCount: Int
        var boundPrefixes: Int
        /// A script or style in HTML, whose text isn't escaped.
        var isRawText = false
        var hasChildren = false
        var lastChildIsText = false
    }

    struct Attribute {
        var name: Range<Int>
        var value: Range<Int>
        /// Where its name's colon is, if it has one.
        var colon: Int? = nil
        var isNamespace = false
        /// `xmlns:xml`, which XMLDocument leaves out.
        var isHidden = false
        /// Given by the DOCTYPE, which libxml2 doesn't check.
        var isDefault = false
    }

    init?(_ text: String) {
        var text = text
        guard let bytes = text.withUTF8({ Self.prepared($0) }) else { return nil }
        self.bytes = bytes
        expansionLimit = max(4 * bytes.count, 1 << 20)
        layoutLimit = max(16 * bytes.count, 64 << 20)
    }

    /// The document as XML reads it: without a byte order mark, and with each line ending made
    /// `\n`. Nil when it holds a character XML doesn't allow, such as a control character.
    static func prepared(_ source: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var index = 0
        if source.count >= 3, source[0] == 0xEF, source[1] == 0xBB, source[2] == 0xBF {
            index = 3
        }
        while index < source.count {
            let unit = source[index]
            if unit >= 0x20 {
                // U+FFFE and U+FFFF.
                if unit == 0xEF, index + 2 < source.count, source[index + 1] == 0xBF, source[index + 2] >= 0xBE {
                    return nil
                }
                bytes.append(unit)
            } else if unit == cr {
                bytes.append(lf)
                if index + 1 < source.count, source[index + 1] == lf {
                    index += 1
                }
            } else if unit == lf || unit == tab {
                bytes.append(unit)
            } else {
                return nil
            }
            index += 1
        }
        return bytes
    }

    mutating func read() throws -> String {
        if starts(with: "<?xml"), isSpace(peek(5)) {
            try readDeclaration()
        }
        while true {
            // No step writes much, so checking between them keeps the layout near its limit.
            guard out.count + doctype.count <= layoutLimit else { throw Malformed() }
            guard index < bytes.count else {
                guard let expansion = expansions.last else { break }
                guard open.count == expansion.depth else { throw Malformed() }
                endExpansion()
                continue
            }
            switch bytes[index] {
            case lessThan:
                try readMarkup()
            case ampersand:
                guard !open.isEmpty else { throw Malformed() }
                try readReference()
            default:
                try readText()
            }
        }
        guard sawRoot, open.isEmpty else { throw Malformed() }
        return assembled()
    }

    /// The declaration XMLDocument writes, then the DOCTYPE, then the rest. They go before the
    /// layout in place, which can be big, so it's copied only into the string.
    mutating func assembled() -> String {
        var head: [UInt8] = []
        if kind == .html {
            // HTML has no declaration, but an empty line where it would be, or the DOCTYPE.
            head = doctype.isEmpty ? [lf] : doctype + [lf, lf]
        } else {
            head = Array("<?xml version=\"".utf8) + (version ?? Array("1.0".utf8)) + [quote]
            let encoding = metaEncoding ?? self.encoding ?? Array("UTF-8".utf8)
            if !encoding.isEmpty {
                head += Array(" encoding=\"".utf8) + encoding + [quote]
            }
            // XMLDocument calls a document standalone when its declaration doesn't say it isn't.
            if version != nil, standalone != false {
                head += Array(" standalone=\"yes\"".utf8)
            }
            head += Array("?>\n".utf8)
            if !doctype.isEmpty {
                head += doctype + [lf, lf]
            }
        }
        out.insert(contentsOf: head, at: 0)
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Reading

    func peek(_ offset: Int = 0) -> UInt8 {
        index + offset < bytes.count ? bytes[index + offset] : 0
    }

    func starts(with prefix: StaticString) -> Bool {
        prefix.withUTF8Buffer { expected in
            index + expected.count <= bytes.count && bytes[index..<index + expected.count].elementsEqual(expected)
        }
    }

    /// Where `marker` next starts, from the reading position on.
    func position(of marker: StaticString) -> Int? {
        marker.withUTF8Buffer { marker in
            var position = index
            while position + marker.count <= bytes.count {
                if bytes[position] == marker[0], bytes[position..<position + marker.count].elementsEqual(marker) {
                    return position
                }
                position += 1
            }
            return nil
        }
    }

    /// Skips whitespace, and says whether there was any.
    @discardableResult
    mutating func skipSpaces() -> Bool {
        let start = index
        while index < bytes.count, isSpace(bytes[index]) {
            index += 1
        }
        return index > start
    }

    mutating func expect(_ unit: UInt8) throws {
        guard peek() == unit else { throw Malformed() }
        index += 1
    }

    /// The character that starts at `position`, and how many bytes it takes.
    func scalar(at position: Int) -> (value: UInt32, length: Int) {
        let first = bytes[position]
        if first < 0x80 {
            return (UInt32(first), 1)
        }
        func continuation(_ offset: Int) -> UInt32 {
            UInt32(bytes[position + offset] & 0x3F)
        }
        if first < 0xE0 {
            return (UInt32(first & 0x1F) << 6 | continuation(1), 2)
        }
        if first < 0xF0 {
            return (UInt32(first & 0x0F) << 12 | continuation(1) << 6 | continuation(2), 3)
        }
        return (UInt32(first & 0x07) << 18 | continuation(1) << 12 | continuation(2) << 6 | continuation(3), 4)
    }

    /// Reads a name, and returns where it is in `bytes`.
    mutating func readName() throws -> Range<Int> {
        let start = index
        guard index < bytes.count, isNameStart(scalar(at: index).value) else { throw Malformed() }
        index += scalar(at: index).length
        skipNameCharacters()
        return start..<index
    }

    /// Reads a name token: name characters, which needn't start as a name does.
    mutating func readNameToken() throws -> Range<Int> {
        let start = index
        skipNameCharacters()
        guard index > start else { throw Malformed() }
        return start..<index
    }

    mutating func skipNameCharacters() {
        while index < bytes.count {
            let unit = bytes[index]
            if unit < 0x80 {
                guard isASCIINameCharacter(unit) else { return }
                index += 1
            } else {
                let (value, length) = scalar(at: index)
                guard isNameCharacter(value) else { return }
                index += length
            }
        }
    }

    /// Reads a quoted literal, and returns what's between the quotes.
    mutating func readQuoted() throws -> Range<Int> {
        let delimiter = peek()
        guard delimiter == quote || delimiter == apostrophe else { throw Malformed() }
        index += 1
        let start = index
        while index < bytes.count, bytes[index] != delimiter {
            index += 1
        }
        guard index < bytes.count else { throw Malformed() }
        index += 1
        return start..<index - 1
    }

    // MARK: - The XML declaration

    mutating func readDeclaration() throws {
        index += 5
        skipSpaces()
        guard starts(with: "version") else { throw Malformed() }
        index += 7
        let version = try readPseudoAttribute()
        // libxml2 reads 1.0 and, with a warning, any other 1.x.
        guard version.count >= 2, bytes[version.lowerBound] == UInt8(ascii: "1"),
            bytes[version.lowerBound + 1] == UInt8(ascii: "."),
            bytes[version.dropFirst(2)].allSatisfy(isDigit)
        else { throw Malformed() }
        self.version = Array(bytes[version])
        // A space lets another part follow.
        var mayContinue = skipSpaces()
        if mayContinue, starts(with: "encoding") {
            index += 8
            let nameRange = try readPseudoAttribute()
            let name = Array(bytes[nameRange])
            guard let first = name.first, isLetter(first),
                name.allSatisfy({ isLetter($0) || isDigit($0) || $0 == dot || $0 == underscore || $0 == minus })
            else { throw Malformed() }
            // The text is UTF-8 by now, so it can't be in these.
            let upper = String(decoding: name, as: UTF8.self).uppercased()
            let wide = ["UTF-16", "UTF16", "UTF-32", "UTF32", "UCS-2", "UCS2", "UCS-4", "UCS4", "ISO-10646-UCS-"]
            guard !wide.contains(where: upper.hasPrefix) else { throw Malformed() }
            encoding = name
            // libxml2 doesn't ask for a space after UTF-8's name.
            mayContinue = skipSpaces() || upper == "UTF-8" || upper == "UTF8"
        }
        if mayContinue, starts(with: "standalone") {
            index += 10
            let valueRange = try readPseudoAttribute()
            let value = bytes[valueRange]
            if value.elementsEqual("yes".utf8) {
                standalone = true
            } else if value.elementsEqual("no".utf8) {
                standalone = false
            } else {
                throw Malformed()
            }
            skipSpaces()
        }
        guard starts(with: "?>") else { throw Malformed() }
        index += 2
    }

    /// Reads `= "value"` after a part of the declaration's name.
    mutating func readPseudoAttribute() throws -> Range<Int> {
        skipSpaces()
        try expect(equals)
        skipSpaces()
        return try readQuoted()
    }

    // MARK: - Markup

    mutating func readMarkup() throws {
        switch peek(1) {
        case slash:
            try readEndTag()
        case question:
            let (target, data) = try readProcessingInstruction()
            flushText()
            guard voidDepth == nil else { return }
            beginChild(isText: false)
            appendInstruction(bytes[target], bytes[data], isHTML: kind == .html, to: &out)
            if !sawRoot {
                prologInstructions.append(out.count - 2)
            }
        case exclamation:
            if starts(with: "<!--") {
                let comment = try readComment()
                flushText()
                guard voidDepth == nil else { return }
                beginChild(isText: false)
                appendComment(bytes[comment], to: &out)
            } else if starts(with: "<![CDATA["), !open.isEmpty {
                try readCDATA()
            } else if starts(with: "<!DOCTYPE"), !sawDoctype, !sawRoot, expansions.isEmpty {
                try readDoctype()
            } else {
                throw Malformed()
            }
        default:
            try readStartTag()
        }
    }

    /// Reads a comment, and returns what's between `<!--` and `-->`.
    mutating func readComment() throws -> Range<Int> {
        index += 4
        let start = index
        while index + 1 < bytes.count {
            if bytes[index] == minus, bytes[index + 1] == minus {
                // Two hyphens may only end it.
                guard index + 2 < bytes.count, bytes[index + 2] == greaterThan else { throw Malformed() }
                index += 3
                return start..<index - 3
            }
            index += 1
        }
        throw Malformed()
    }

    /// Reads a processing instruction, and returns its target and its data.
    mutating func readProcessingInstruction() throws -> (target: Range<Int>, data: Range<Int>) {
        index += 2
        let target = try readName()
        // "xml" in any case is kept for the declaration, and colons are a namespace error.
        let name = bytes[target]
        if name.count == 3, name.map({ $0 | 0x20 }).elementsEqual("xml".utf8) {
            throw Malformed()
        }
        guard !name.contains(colon) else { throw Malformed() }
        if starts(with: "?>") {
            index += 2
            return (target, index..<index)
        }
        guard skipSpaces() else { throw Malformed() }
        let start = index
        guard let end = position(of: "?>") else { throw Malformed() }
        index = end + 2
        return (target, start..<end)
    }

    mutating func readCDATA() throws {
        index += 9
        let start = index
        guard let end = position(of: "]]>") else { throw Malformed() }
        index = end + 3
        // XMLDocument keeps it as text, joined to the text around it.
        for unit in bytes[start..<end] {
            appendTextUnit(unit)
        }
    }

    // MARK: - Text and references

    mutating func readText() throws {
        let start = index
        var isBlank = true
        var hasGreaterThan = false
        while index < bytes.count {
            let unit = bytes[index]
            if unit == lessThan || unit == ampersand { break }
            if unit == greaterThan {
                // "]]>" can't be in text.
                if index - start >= 2, bytes[index - 1] == rightBracket, bytes[index - 2] == rightBracket {
                    throw Malformed()
                }
                hasGreaterThan = true
            }
            if isBlank, !isSpace(unit) {
                isBlank = false
            }
            index += 1
        }
        // Outside the root, there can only be whitespace, which the layout leaves out.
        guard !open.isEmpty else {
            guard isBlank else { throw Malformed() }
            return
        }
        if !isBlank {
            textIsBlank = false
        }
        if hasGreaterThan, !isInRawText {
            for unit in bytes[start..<index] {
                appendTextUnit(unit)
            }
        } else {
            text += bytes[start..<index]
        }
    }

    /// Whether the text being read is in an HTML script or style.
    var isInRawText: Bool {
        open.last?.isRawText ?? false
    }

    mutating func appendTextUnit(_ unit: UInt8) {
        if isInRawText {
            textIsBlank = textIsBlank && isSpace(unit)
            text.append(unit)
            return
        }
        switch unit {
        case ampersand: text += escapedAmpersand
        case lessThan: text += escapedLessThan
        case greaterThan: text += escapedGreaterThan
        default:
            if textIsBlank, !isSpace(unit) {
                textIsBlank = false
            }
            text.append(unit)
            return
        }
        textIsBlank = false
    }

    /// Reads a reference in an element's content.
    mutating func readReference() throws {
        if peek(1) == hash {
            var units: [UInt8] = []
            appendUTF8(try readCharacterReference(), to: &units)
            for unit in units {
                appendTextUnit(unit)
            }
            return
        }
        index += 1
        let name = try readName()
        try expect(semicolon)
        if let character = predefinedEntity(bytes[name]) {
            appendTextUnit(character)
            return
        }
        let key = Array(bytes[name])
        guard let entity = generalEntities[key] else {
            // libxml2 refuses one that's undeclared in another entity's text.
            guard mayLeaveEntitiesUndeclared, expansions.isEmpty else { throw Malformed() }
            // XMLDocument leaves it out, and the text on each side of it stays apart.
            flushText()
            return
        }
        // And one declared in a parameter entity, used in an entity that wasn't.
        if entity.isFromParameterEntity, let outer = expansions.last, !outer.isFromParameterEntity {
            throw Malformed()
        }
        switch entity.kind {
        case .external:
            // XMLDocument leaves out what it would have to load.
            break
        case .externalWithoutSystemID, .unparsed:
            throw Malformed()
        case .text(let replacement):
            try beginExpansion(of: key, entity, replacement)
        }
    }

    /// Whether an undeclared entity is allowed, as when the external subset could declare it.
    var mayLeaveEntitiesUndeclared: Bool {
        hasExternalSubset && standalone != true
    }

    /// Reads `&#…;`, and returns the character it stands for.
    mutating func readCharacterReference() throws -> UInt32 {
        index += 2
        var value: UInt32 = 0
        var digits = 0
        if peek() == UInt8(ascii: "x") {
            index += 1
            while let digit = hexValue(peek()) {
                value = min(value * 16 + digit, 0x11_0000)
                digits += 1
                index += 1
            }
        } else {
            while isDigit(peek()) {
                value = min(value * 10 + UInt32(peek() - UInt8(ascii: "0")), 0x11_0000)
                digits += 1
                index += 1
            }
        }
        guard digits > 0, isCharacter(value) else { throw Malformed() }
        try expect(semicolon)
        return value
    }

    /// Reads an entity's replacement text in place of its reference.
    mutating func beginExpansion(of name: [UInt8], _ entity: Entity, _ replacement: [UInt8], isParameter: Bool = false)
        throws
    {
        // An entity can't refer to itself, however indirectly.
        guard expanding.insert(EntityName(name: name, isParameter: isParameter)).inserted else { throw Malformed() }
        expanded += replacement.count
        guard expanded <= expansionLimit else { throw Malformed() }
        expansions.append(
            Expansion(
                name: name, isParameter: isParameter, isFromParameterEntity: entity.isFromParameterEntity,
                outer: bytes, outerIndex: index, depth: open.count))
        if isParameter {
            parameterExpansions += 1
        }
        bytes = replacement
        index = 0
    }

    mutating func endExpansion() {
        let expansion = expansions.removeLast()
        if expansion.isParameter {
            parameterExpansions -= 1
        }
        expanding.remove(EntityName(name: expansion.name, isParameter: expansion.isParameter))
        bytes = expansion.outer
        index = expansion.outerIndex
    }

    // MARK: - Elements

    mutating func readStartTag() throws {
        // There's one root element.
        guard !(open.isEmpty && sawRoot) else { throw Malformed() }
        index += 1
        let name = try readName()
        tagBytes.removeAll(keepingCapacity: true)
        attributes.removeAll(keepingCapacity: true)
        tagBytes += bytes[name]
        let elementName = 0..<name.count
        var isEmpty = false
        while true {
            let spaced = skipSpaces()
            if peek() == greaterThan {
                index += 1
                break
            }
            if peek() == slash, peek(1) == greaterThan {
                index += 2
                isEmpty = true
                break
            }
            guard spaced else { throw Malformed() }
            let attributeName = try readName()
            let nameStart = tagBytes.count
            tagBytes += bytes[attributeName]
            let nameEnd = tagBytes.count
            skipSpaces()
            try expect(equals)
            skipSpaces()
            try readAttributeValue()
            let separator = tagBytes[nameStart..<nameEnd].firstIndex(of: colon)
            attributes.append(Attribute(name: nameStart..<nameEnd, value: nameEnd..<tagBytes.count, colon: separator))
        }
        try checkUniqueAttributes()
        let types = attributeTypes.isEmpty ? nil : attributeTypes[Array(tagBytes[elementName])]
        if let types {
            normalizeDeclaredAttributes(types)
        }
        let defaults = attributeDefaults.isEmpty ? [] : try addNamespaceDefaults(elementName)
        var bound = try bindNamespaces(elementName, defaults: defaults)
        try checkIDs(types)
        if !sawRoot {
            bound += chooseKind(root: elementName)
        }
        sawRoot = true

        flushText()
        let isPrefixed = tagBytes[elementName].contains(colon)
        // HTML and XHTML go by the names they know, in any case.
        let lowercased = kind == .xml || isPrefixed ? [] : lowercasedASCII(tagBytes[elementName])
        let isVoid = kind != .xml && voidElements.contains(lowercased)
        if kind == .xhtml {
            noteMetaEncoding(lowercased)
        }
        guard voidDepth == nil else {
            // Nothing in a void element is written.
            if isEmpty {
                unbindNamespaces(bound)
            } else {
                push(elementName, bound: bound)
            }
            return
        }
        beginChild(isText: false)
        out.append(lessThan)
        appendName(tagBytes[elementName])
        // HTML writes an element with a prefix as XML. Either way, namespaces come first.
        let isHTML = kind == .html && !isPrefixed
        for attribute in attributes where attribute.isNamespace && !attribute.isHidden {
            appendAttribute(attribute, isHTML: isHTML)
        }
        for attribute in attributes where !attribute.isNamespace {
            appendAttribute(attribute, isHTML: isHTML)
        }
        if isVoid {
            out += kind == .xhtml ? [space, slash, greaterThan] : [greaterThan]
            if isEmpty {
                unbindNamespaces(bound)
            } else {
                push(elementName, bound: bound)
                voidDepth = open.count
            }
            return
        }
        out.append(greaterThan)
        if isEmpty {
            out += [lessThan, slash]
            appendName(tagBytes[elementName])
            out.append(greaterThan)
            unbindNamespaces(bound)
        } else {
            let isRawText =
                kind == .html && (lowercased.elementsEqual("script".utf8) || lowercased.elementsEqual("style".utf8))
            push(elementName, bound: bound, isRawText: isRawText)
        }
    }

    mutating func push(_ elementName: Range<Int>, bound: Int, isRawText: Bool = false) {
        open.append(
            OpenElement(
                nameStart: names.count, nameCount: elementName.count, boundPrefixes: bound, isRawText: isRawText))
        names += tagBytes[elementName]
    }

    /// Writes an element's name, which XHTML makes lowercase unless it has a prefix.
    mutating func appendName(_ name: ArraySlice<UInt8>) {
        if kind == .xhtml, !name.contains(colon) {
            out += lowercasedASCII(name)
        } else {
            out += name
        }
    }

    /// XMLDocument writes a document whose root is `html` as HTML, or as XHTML when it's in XHTML's
    /// namespace. Returns how many namespaces this binds.
    mutating func chooseKind(root: Range<Int>) -> Int {
        guard lowercasedASCII(tagBytes[root]).elementsEqual("html".utf8) else { return 0 }
        let namespace = namespaces[[]]?.last
        if let namespace, namespace == uriNumbers[xhtmlNamespace] {
            kind = .xhtml
            return 0
        }
        // XMLDocument takes XHTML 1.0's DTDs at their word, and writes the namespace they give
        // `html`. With another namespace, it stops the app instead, so this keeps to HTML.
        if namespace == nil, let systemID = doctypeSystemID, systemID.starts(with: xhtmlSystemID) {
            kind = .xhtml
            let start = tagBytes.count
            tagBytes += Array("xmlns".utf8)
            tagBytes += xhtmlNamespace
            attributes.append(Attribute(name: start..<start + 5, value: start + 5..<tagBytes.count, isNamespace: true))
            namespaces[[], default: []].append(number(of: xhtmlNamespace))
            boundPrefixes.append([])
            return 1
        }
        kind = .html
        out = removing(prologInstructions, from: out)
        doctype = removing(doctypeInstructions, from: doctype)
        return 0
    }

    /// Adds the namespaces the DOCTYPE gives the element by default, unless it declares them, or
    /// they're bound that way already as libxml2 tells, and returns the names of its other
    /// defaults, which have prefixes. They're read again for each element, so they count toward
    /// `layoutLimit`, written or not.
    mutating func addNamespaceDefaults(_ elementName: Range<Int>) throws -> [[UInt8]] {
        let element = Array(tagBytes[elementName])
        guard let defaults = attributeDefaults[element] else { return [] }
        let first = firstDefaults[element]
        // The names the tag has, so each default is looked for once.
        var present = Set(attributes.map { Array(tagBytes[$0.name]) })
        var prefixed: [[UInt8]] = []
        for item in defaults {
            defaultsRead += item.name.count
            guard defaultsRead <= layoutLimit else { throw Malformed() }
            guard !present.contains(item.name) else { continue }
            guard let number = item.namespace else {
                prefixed.append(item.name)
                continue
            }
            let prefix = item.name.count > 6 ? Array(item.name[6...]) : []
            if item.name.count > 6 {
                // libxml2 compares the namespace the prefix has with the value of the element's
                // first default, whichever that is, rather than with this one's.
                guard namespaces[prefix]?.last != first else { continue }
            } else {
                // It reads an empty default namespace as none, which never matches, so it adds
                // one each time.
                guard item.value.isEmpty || namespaces[prefix]?.last != number else { continue }
            }
            defaultsRead += item.value.count
            guard defaultsRead <= layoutLimit else { throw Malformed() }
            let start = tagBytes.count
            // `xmlns:` with no prefix after it is the default namespace.
            let name = prefix.isEmpty ? Array("xmlns".utf8) : item.name
            present.insert(name)
            tagBytes += name
            tagBytes += item.value
            attributes.append(
                Attribute(
                    name: start..<start + name.count, value: start + name.count..<tagBytes.count,
                    colon: name.count > 6 ? start + 5 : nil, isDefault: true))
        }
        return prefixed
    }

    /// Notes the encoding that an XHTML head's `<meta http-equiv="Content-Type">` names.
    mutating func noteMetaEncoding(_ lowercasedName: [UInt8]) {
        // The parent's length first, since a long name would take long to make lowercase for each.
        guard !sawContentTypeMeta, lowercasedName.elementsEqual("meta".utf8), open.count == 2, open[1].nameCount == 4,
            lowercasedASCII(names[open[1].nameStart..<open[1].nameStart + 4]).elementsEqual("head".utf8)
        else { return }
        var isContentType = false
        var content: ArraySlice<UInt8>?
        for attribute in attributes {
            let name = lowercasedASCII(tagBytes[attribute.name])
            if name.elementsEqual("http-equiv".utf8) {
                isContentType = lowercasedASCII(tagBytes[attribute.value]).elementsEqual("content-type".utf8)
            } else if name.elementsEqual("content".utf8) {
                content = tagBytes[attribute.value]
            }
        }
        guard isContentType, let content else { return }
        // The first one counts, and names whatever follows `charset=`, as it is.
        sawContentTypeMeta = true
        let lowercasedContent = lowercasedASCII(content)
        let marker = Array("charset=".utf8)
        guard let offset = lowercasedContent.indices.first(where: { lowercasedContent[$0...].starts(with: marker) })
        else { return }
        metaEncoding = Array(content.dropFirst(offset + marker.count))
    }

    mutating func appendAttribute(_ attribute: Attribute, isHTML: Bool) {
        out.append(space)
        out += tagBytes[attribute.name]
        // HTML writes a boolean attribute by its name alone.
        if isHTML, booleanAttributes.contains(lowercasedASCII(tagBytes[attribute.name])) {
            return
        }
        out += [equals, quote]
        // XMLDocument writes a namespace's URI as it is, since a URI's characters need no escaping,
        // but for a quote, which only a default from the DOCTYPE can have.
        guard !attribute.isNamespace else {
            for unit in tagBytes[attribute.value] {
                if unit == quote {
                    out += escapedQuote
                } else {
                    out.append(unit)
                }
            }
            out.append(quote)
            return
        }
        for unit in tagBytes[attribute.value] {
            switch unit {
            case ampersand: out += escapedAmpersand
            case quote: out += escapedQuote
            // HTML leaves these as they are.
            case lessThan where !isHTML: out += escapedLessThan
            case greaterThan where !isHTML: out += escapedGreaterThan
            default: out.append(unit)
            }
        }
        out.append(quote)
    }

    mutating func readEndTag() throws {
        index += 2
        let name = try readName()
        skipSpaces()
        try expect(greaterThan)
        // It must close the element that's open, and one opened in the same entity.
        guard let element = open.last, open.count > (expansions.last?.depth ?? 0),
            names[element.nameStart..<element.nameStart + element.nameCount].elementsEqual(bytes[name])
        else { throw Malformed() }
        flushText()
        let closed = open.removeLast()
        defer {
            names.removeLast(closed.nameCount)
            unbindNamespaces(closed.boundPrefixes)
        }
        // A void element has no end tag, and nothing in it is written.
        if let depth = voidDepth {
            if open.count < depth {
                voidDepth = nil
            }
            return
        }
        if closed.hasChildren, !closed.lastChildIsText {
            newLine(depth: open.count)
        }
        out += [lessThan, slash]
        appendName(names[closed.nameStart...])
        out.append(greaterThan)
    }

    /// Reads a quoted attribute value onto `tagBytes`, with its references replaced and each
    /// whitespace character made a space, as XML normalizes it.
    mutating func readAttributeValue() throws {
        let delimiter = peek()
        guard delimiter == quote || delimiter == apostrophe else { throw Malformed() }
        index += 1
        let level = expansions.count
        // libxml2 refuses an undeclared entity in a tag that's in an entity's text.
        let isInEntity = expansions.count > parameterExpansions
        while true {
            guard index < bytes.count else {
                // The value ends in the document, not in an entity.
                guard expansions.count > level else { throw Malformed() }
                endExpansion()
                continue
            }
            let unit = bytes[index]
            if unit == delimiter, expansions.count == level {
                index += 1
                return
            }
            switch unit {
            case lessThan:
                throw Malformed()
            case ampersand:
                if peek(1) == hash {
                    appendUTF8(try readCharacterReference(), to: &tagBytes)
                    continue
                }
                index += 1
                let name = try readName()
                try expect(semicolon)
                if let character = predefinedEntity(bytes[name]) {
                    tagBytes.append(character)
                    continue
                }
                let key = Array(bytes[name])
                guard let entity = generalEntities[key] else {
                    guard mayLeaveEntitiesUndeclared, !isInEntity else { throw Malformed() }
                    continue
                }
                guard case .text(let replacement) = entity.kind else { throw Malformed() }
                try beginExpansion(of: key, entity, replacement)
            case space, tab, lf, cr:
                tagBytes.append(space)
                index += 1
            default:
                tagBytes.append(unit)
                index += 1
            }
        }
    }

    func checkUniqueAttributes() throws {
        if attributes.count <= 16 {
            for (offset, attribute) in attributes.enumerated() {
                for other in attributes[..<offset] where tagBytes[other.name].elementsEqual(tagBytes[attribute.name]) {
                    throw Malformed()
                }
            }
        } else {
            var seen: Set<ArraySlice<UInt8>> = []
            for attribute in attributes {
                guard seen.insert(tagBytes[attribute.name]).inserted else { throw Malformed() }
            }
        }
    }

    /// Collapses the spaces in values the DOCTYPE declares as something other than CDATA, given
    /// the element's declared types.
    mutating func normalizeDeclaredAttributes(_ types: [[UInt8]: AttributeType]) {
        for offset in attributes.indices where types[Array(tagBytes[attributes[offset].name])] != nil {
            let collapsed = collapsingSpaces(tagBytes[attributes[offset].value])
            let start = tagBytes.count
            tagBytes += collapsed
            attributes[offset].value = start..<tagBytes.count
        }
    }

    /// Checks the namespaces the element and its attributes use, and binds the ones it declares.
    /// Returns how many it bound.
    mutating func bindNamespaces(_ elementName: Range<Int>, defaults: [[UInt8]] = []) throws -> Int {
        guard isQualifiedName(tagBytes[elementName]) else { throw Malformed() }
        var bound = 0
        var prefixed = 0
        for offset in attributes.indices {
            let attribute = attributes[offset]
            let name = tagBytes[attribute.name]
            guard attribute.isDefault || isQualifiedName(name) else { throw Malformed() }
            let prefix: [UInt8]
            if name.elementsEqual("xmlns".utf8) {
                prefix = []
                let uri = Array(tagBytes[attribute.value])
                if !uri.isEmpty, !attribute.isDefault {
                    guard isURIReference(uri), uri != xmlNamespace, uri != xmlnsNamespace else { throw Malformed() }
                }
                namespaces[prefix, default: []].append(number(of: uri))
            } else if let separator = attribute.colon,
                tagBytes[attribute.name.lowerBound..<separator].elementsEqual("xmlns".utf8)
            {
                prefix = Array(tagBytes[separator + 1..<attribute.name.upperBound])
                let uri = Array(tagBytes[attribute.value])
                attributes[offset].isNamespace = true
                if prefix.elementsEqual("xml".utf8) {
                    // It may only say what it's always bound to, and XMLDocument leaves it out.
                    guard uri == xmlNamespace else { throw Malformed() }
                    attributes[offset].isHidden = true
                    continue
                }
                guard
                    attribute.isDefault
                        || (uri != xmlNamespace && !prefix.elementsEqual("xmlns".utf8) && uri != xmlnsNamespace
                            && !uri.isEmpty && isURIReference(uri))
                else { throw Malformed() }
                namespaces[prefix, default: []].append(number(of: uri))
            } else {
                if attribute.colon != nil {
                    prefixed += 1
                }
                continue
            }
            attributes[offset].isNamespace = true
            boundPrefixes.append(prefix)
            bound += 1
        }
        if let separator = tagBytes[elementName].firstIndex(of: colon) {
            guard namespace(of: tagBytes[elementName.lowerBound..<separator]) != nil else { throw Malformed() }
        }
        guard prefixed + defaults.count > 0 else { return bound }
        // Each prefix must be bound, and no two attributes may have the same name in the same
        // namespace, the defaults included.
        let qualified =
            attributes.filter { !$0.isNamespace && $0.colon != nil }.map { Array(tagBytes[$0.name]) } + defaults
        var seen: Set<ExpandedName> = []
        for name in qualified {
            guard let separator = name.firstIndex(of: colon) else { continue }
            guard let namespace = namespace(of: name[..<separator]) else { throw Malformed() }
            if qualified.count > 1 {
                let expandedName = ExpandedName(namespace: namespace, localName: name[(separator + 1)...])
                guard seen.insert(expandedName).inserted else { throw Malformed() }
            }
        }
        return bound
    }

    /// The number of the namespace a prefix is bound to.
    func namespace(of prefix: ArraySlice<UInt8>) -> Int? {
        if prefix.elementsEqual("xml".utf8) {
            return 0
        }
        return namespaces[Array(prefix)]?.last
    }

    mutating func number(of uri: [UInt8]) -> Int {
        if let number = uriNumbers[uri] {
            return number
        }
        uriNumbers[uri] = uriNumbers.count
        return uriNumbers.count - 1
    }

    mutating func unbindNamespaces(_ count: Int) {
        for _ in 0..<count {
            let prefix = boundPrefixes.removeLast()
            namespaces[prefix]?.removeLast()
        }
    }

    /// XMLDocument refuses an ID used twice, and an `xml:id` that isn't a name without colons,
    /// though spaces may surround it. libxml2 checks that name with older rules, which this
    /// doesn't copy.
    mutating func checkIDs(_ types: [[UInt8]: AttributeType]?) throws {
        for attribute in attributes {
            let name = tagBytes[attribute.name]
            let value = tagBytes[attribute.value]
            if name.elementsEqual("xml:id".utf8) {
                let trimmed = value.drop(while: isSpace).reversed().drop(while: isSpace).reversed()
                guard isName(ArraySlice(trimmed)), !value.contains(colon), ids.insert(Array(value)).inserted else {
                    throw Malformed()
                }
            } else if !value.isEmpty, types?[Array(name)] == .id {
                guard ids.insert(Array(value)).inserted else { throw Malformed() }
            }
        }
    }

    // MARK: - Layout

    /// Starts a line for the next node in the open element, unless it follows text, or it's text
    /// that comes first. That's how XMLDocument lays out mixed content.
    mutating func beginChild(isText: Bool) {
        guard let last = open.indices.last else {
            // Outside the root, each node has a line.
            if !out.isEmpty {
                out.append(lf)
            }
            return
        }
        let breaksLine = open[last].hasChildren ? !open[last].lastChildIsText : !isText
        if breaksLine {
            newLine(depth: open.count)
        }
        open[last].hasChildren = true
        open[last].lastChildIsText = isText
    }

    mutating func newLine(depth: Int) {
        out.append(lf)
        out += repeatElement(space, count: 4 * min(depth, XMLLayout.deepestIndent))
    }

    /// Writes the text read since the last markup, unless it's only whitespace, which XMLDocument
    /// leaves out.
    mutating func flushText() {
        guard !text.isEmpty else { return }
        if !textIsBlank, voidDepth == nil {
            beginChild(isText: true)
            out += text
        }
        text.removeAll(keepingCapacity: true)
        textIsBlank = true
    }
}

// These aren't the reader's methods, since a method of the reader that's passed `&out` makes
// Swift copy the reader, and so the whole layout, each time it's called.

private func appendComment(_ comment: ArraySlice<UInt8>, to destination: inout [UInt8]) {
    destination += Array("<!--".utf8)
    destination += comment
    destination += Array("-->".utf8)
}

private func appendInstruction(
    _ target: ArraySlice<UInt8>, _ data: ArraySlice<UInt8>, isHTML: Bool, to destination: inout [UInt8]
) {
    destination += [lessThan, question]
    destination += target
    if !data.isEmpty {
        destination.append(space)
        destination += data
    }
    // HTML ends them without `?`.
    destination += isHTML ? [greaterThan] : [question, greaterThan]
}

// MARK: - The DOCTYPE

extension XMLReader {
    mutating func readDoctype() throws {
        sawDoctype = true
        index += 9
        skipSpaces()
        let name = try readName()
        doctype = Array("<!DOCTYPE ".utf8) + bytes[name]
        skipSpaces()
        if starts(with: "SYSTEM") {
            index += 6
            guard skipSpaces() else { throw Malformed() }
            let system = try readQuoted()
            doctype += Array(" SYSTEM \"".utf8)
            doctype += bytes[system]
            doctype.append(quote)
            doctypeSystemID = Array(bytes[system])
            hasExternalSubset = true
        } else if starts(with: "PUBLIC") {
            index += 6
            guard skipSpaces() else { throw Malformed() }
            let publicID = try readPublicID()
            guard skipSpaces() else { throw Malformed() }
            let system = try readQuoted()
            doctype += Array(" PUBLIC \"".utf8)
            doctype += bytes[publicID]
            doctype += Array("\" \"".utf8)
            doctype += bytes[system]
            doctype.append(quote)
            doctypeSystemID = Array(bytes[system])
            hasExternalSubset = true
        }
        skipSpaces()
        var subset: [UInt8] = []
        if peek() == leftBracket {
            guard findsInternalSubsetEnd() else { throw Malformed() }
            index += 1
            try readInternalSubset(into: &subset)
            index += 1
            skipSpaces()
        } else if peek() == greaterThan, peek(1) == leftBracket {
            // libxml2 still reads an internal subset right after the `>`.
            index += 1
            guard findsInternalSubsetEnd() else { throw Malformed() }
            index += 1
            try readInternalSubset(into: &subset)
            index += 1
            skipSpaces()
        }
        try expect(greaterThan)
        if subset.isEmpty {
            doctype.append(greaterThan)
        } else {
            doctype += Array(" [\n".utf8)
            doctypeInstructions = doctypeInstructions.map { $0 + doctype.count }
            doctype += subset
            doctype += [rightBracket, greaterThan]
        }
    }

    /// Whether libxml2 finds where the internal subset ends before it reads it, as it does when
    /// NSXMLParser feeds it the document: a `]`, maybe spaces, and `>`, outside quotes and
    /// comments. A quote or a comment that's never closed hides the end, and it refuses the document.
    func findsInternalSubsetEnd() -> Bool {
        var position = index
        var delimiter: UInt8 = 0
        while position < bytes.count {
            let unit = bytes[position]
            if delimiter != 0 {
                if unit == delimiter {
                    delimiter = 0
                }
                position += 1
                continue
            }
            if unit == lessThan, position + 4 < bytes.count, bytes[position + 1] == exclamation,
                bytes[position + 2] == minus, bytes[position + 3] == minus
            {
                // A comment, which libxml2 looks for the end of from its start, so `<!-->` is one.
                var end = position
                while end + 3 < bytes.count, !bytes[end...].starts(with: "-->".utf8) {
                    end += 1
                }
                guard end + 3 < bytes.count else { return false }
                position = end + 3
                continue
            }
            if unit == quote || unit == apostrophe {
                delimiter = unit
            } else if unit == rightBracket {
                // Two are a conditional section's end.
                guard position + 1 < bytes.count else { return false }
                if bytes[position + 1] == rightBracket {
                    position += 2
                    continue
                }
                var ahead = position + 1
                while ahead < bytes.count, isSpace(bytes[ahead]) {
                    ahead += 1
                }
                guard ahead < bytes.count else { return false }
                if bytes[ahead] == greaterThan {
                    return true
                }
            }
            position += 1
        }
        return false
    }

    /// Reads a public ID's literal, which allows only some characters.
    mutating func readPublicID() throws -> Range<Int> {
        let literal = try readQuoted()
        guard bytes[literal].allSatisfy(isPublicIDCharacter) else { throw Malformed() }
        return literal
    }

    /// Reads the declarations between `[` and `]`, and writes the ones XMLDocument keeps, one per
    /// line.
    mutating func readInternalSubset(into subset: inout [UInt8]) throws {
        let level = expansions.count
        skipSpaces()
        while true {
            guard index < bytes.count else {
                guard expansions.count > level else { throw Malformed() }
                endExpansion()
                skipSpaces()
                continue
            }
            switch bytes[index] {
            case rightBracket:
                guard expansions.count == level else { throw Malformed() }
                return
            case lessThan:
                var line: [UInt8] = []
                if starts(with: "<!ELEMENT") {
                    try readElementDeclaration(into: &line)
                } else if starts(with: "<!ATTLIST") {
                    try readAttributeListDeclaration(into: &subset)
                } else if starts(with: "<!ENTITY") {
                    try readEntityDeclaration(into: &line)
                } else if starts(with: "<!NOTATION") {
                    // XMLDocument doesn't write notations.
                    try readNotationDeclaration()
                } else if starts(with: "<!--") {
                    appendComment(bytes[try readComment()], to: &line)
                } else if starts(with: "<?") {
                    let (target, data) = try readProcessingInstruction()
                    appendInstruction(bytes[target], bytes[data], isHTML: false, to: &line)
                    // Where its `?` is in the subset, once the line is written.
                    doctypeInstructions.append(subset.count + 4 + line.count - 2)
                } else {
                    throw Malformed()
                }
                try appendLine(line, to: &subset)
                if expansions.count == level {
                    lastParameterEntity = nil
                }
            case percent:
                try readParameterEntityReference()
            default:
                throw Malformed()
            }
            skipSpaces()
        }
    }

    /// Writes a line of the DOCTYPE, which counts toward `layoutLimit`, since an `<!ATTLIST>`'s
    /// lines each repeat its element's name.
    func appendLine(_ line: [UInt8], to subset: inout [UInt8]) throws {
        guard !line.isEmpty else { return }
        subset += repeatElement(space, count: 4)
        subset += line
        subset.append(lf)
        guard subset.count <= layoutLimit else { throw Malformed() }
    }

    mutating func readParameterEntityReference() throws {
        index += 1
        let name = Array(bytes[try readName()])
        try expect(semicolon)
        // The Mac reads these only when the DOCTYPE names an external subset.
        guard hasExternalSubset else { throw Malformed() }
        guard let entity = parameterEntities[name] else {
            guard standalone != true else { throw Malformed() }
            return
        }
        guard case .text(let replacement) = entity.kind else { return }
        guard lastParameterEntity != name else { throw Malformed() }
        lastParameterEntity = name
        try beginExpansion(of: name, entity, replacement, isParameter: true)
    }

    // MARK: Elements

    mutating func readElementDeclaration(into line: inout [UInt8]) throws {
        index += 9
        guard skipSpaces() else { throw Malformed() }
        let name = Array(bytes[try readName()])
        guard skipSpaces() else { throw Malformed() }
        line = Array("<!ELEMENT ".utf8) + name + [space]
        if starts(with: "EMPTY") {
            index += 5
            line += Array("EMPTY".utf8)
        } else if starts(with: "ANY") {
            index += 3
            line += Array("ANY".utf8)
        } else if peek() == leftParenthesis {
            index += 1
            skipSpaces()
            var model = ContentModel()
            let root = try starts(with: "#PCDATA") ? readMixedContent(&model) : readChildren(&model)
            model.write(root, into: &line)
        } else {
            throw Malformed()
        }
        skipSpaces()
        try expect(greaterThan)
        // XMLDocument fails on a second declaration of an element.
        guard declaredElements.insert(name).inserted else { throw Malformed() }
        line.append(greaterThan)
    }

    /// Reads `#PCDATA` and the names after it, as libxml2 builds them.
    mutating func readMixedContent(_ model: inout ContentModel) throws -> Int {
        index += 7
        skipSpaces()
        let text = model.add(ContentModel.Particle(kind: .text))
        if peek() == rightParenthesis {
            index += 1
            if peek() == star {
                index += 1
                model.particles[text].occurrence = star
            }
            return text
        }
        var root = text
        var current = text
        var pending: [UInt8]?
        while peek() == pipe {
            index += 1
            if let name = pending {
                let element = model.add(ContentModel.Particle(kind: .element, name: name))
                let choice = model.add(ContentModel.Particle(kind: .choice, first: element))
                model.particles[current].second = choice
                current = choice
            } else {
                root = model.add(ContentModel.Particle(kind: .choice, first: current))
                current = root
            }
            skipSpaces()
            pending = Array(bytes[try readName()])
            skipSpaces()
        }
        guard peek() == rightParenthesis, peek(1) == star, let name = pending else { throw Malformed() }
        index += 2
        model.particles[current].second = model.add(ContentModel.Particle(kind: .element, name: name))
        model.particles[root].occurrence = star
        return root
    }

    /// Reads a content model of elements, as libxml2 builds it: a list joins its particles in
    /// pairs, `(a, b, c)` as `(a, (b, c))`, and some repetition marks are moved or dropped. Like
    /// XMLParser, it refuses groups nested more than `deepestGroup` deep, which also keeps
    /// `repeatGroup` from going over a long list once for each group around it.
    mutating func readChildren(_ model: inout ContentModel) throws -> Int {
        struct Group {
            var first = -1
            var current = -1
            var last = -1
            var separator: UInt8 = 0
        }
        var groups = [Group()]
        while true {
            skipSpaces()
            if peek() == leftParenthesis {
                index += 1
                groups.append(Group())
                guard groups.count <= ContentModel.deepestGroup else { throw Malformed() }
                continue
            }
            let name = Array(bytes[try readName()])
            var particle = model.add(ContentModel.Particle(kind: .element, name: name, occurrence: readOccurrence()))
            // Place it, then read a separator, or close groups until one follows.
            while true {
                let group = groups.count - 1
                if groups[group].first == -1 {
                    groups[group].first = particle
                    groups[group].current = particle
                } else {
                    groups[group].last = particle
                }
                skipSpaces()
                let unit = peek()
                if unit == comma || unit == pipe {
                    if groups[group].separator == 0 {
                        groups[group].separator = unit
                    } else if groups[group].separator != unit {
                        throw Malformed()
                    }
                    index += 1
                    let pair = model.add(ContentModel.Particle(kind: unit == comma ? .sequence : .choice))
                    if groups[group].last == -1 {
                        model.particles[pair].first = groups[group].first
                        groups[group].first = pair
                    } else {
                        model.particles[groups[group].current].second = pair
                        model.particles[pair].first = groups[group].last
                        groups[group].last = -1
                    }
                    groups[group].current = pair
                    break
                }
                try expect(rightParenthesis)
                let closed = groups.removeLast()
                if closed.current != -1, closed.last != -1 {
                    model.particles[closed.current].second = closed.last
                }
                model.repeatGroup(closed.first, last: closed.current, by: readOccurrence())
                if groups.isEmpty {
                    return closed.first
                }
                particle = closed.first
            }
        }
    }

    mutating func readOccurrence() -> UInt8 {
        let unit = peek()
        guard unit == question || unit == star || unit == plus else { return 0 }
        index += 1
        return unit
    }

    // MARK: Attributes

    mutating func readAttributeListDeclaration(into subset: inout [UInt8]) throws {
        index += 9
        guard skipSpaces() else { throw Malformed() }
        let element = Array(bytes[try readName()])
        skipSpaces()
        // What's known of the element, kept aside while its attributes are read, so its name,
        // which can be long, is looked up once.
        var declared = declaredAttributes.removeValue(forKey: element) ?? []
        var types = attributeTypes.removeValue(forKey: element) ?? [:]
        var defaults = attributeDefaults.removeValue(forKey: element) ?? []
        var first = firstDefaults[element]
        var hasID = elementsWithID.contains(element)
        while peek() != greaterThan {
            let attribute = Array(bytes[try readName()])
            guard skipSpaces() else { throw Malformed() }
            let (type, typeText) = try readAttributeType()
            guard skipSpaces() else { throw Malformed() }
            var defaultText: [UInt8]
            var defaultValue: [UInt8]?
            if starts(with: "#REQUIRED") {
                index += 9
                defaultText = Array("#REQUIRED".utf8)
            } else if starts(with: "#IMPLIED") {
                index += 8
                defaultText = Array("#IMPLIED".utf8)
            } else {
                defaultText = []
                defaultValue = []
                if starts(with: "#FIXED") {
                    index += 6
                    guard skipSpaces() else { throw Malformed() }
                    defaultText = Array("#FIXED ".utf8)
                }
                tagBytes.removeAll(keepingCapacity: true)
                try readAttributeValue()
                var value = Array(tagBytes)
                if type != .cdata {
                    value = collapsingSpaces(value[...])
                }
                // XMLDocument fails on a default that the type doesn't allow.
                guard isValid(value, for: type) else { throw Malformed() }
                defaultText += [quote] + value + [quote]
                defaultValue = value
            }
            if peek() != greaterThan {
                guard skipSpaces() else { throw Malformed() }
            }
            // libxml2 splits the attribute's name at its prefix.
            guard splitsAtPrefix(attribute) else { throw Malformed() }
            // XMLDocument fails when `xml:id` isn't an ID.
            if attribute.elementsEqual("xml:id".utf8), type != .id {
                throw Malformed()
            }
            // The first declaration of an attribute counts.
            guard declared.insert(attribute).inserted else { continue }
            if type == .id {
                // XMLDocument fails on two IDs for one element.
                guard !hasID else { throw Malformed() }
                hasID = true
            }
            if type != .cdata {
                types[attribute] = type
            }
            if let defaultValue {
                if first == nil {
                    first = number(of: defaultValue)
                }
                if attribute.elementsEqual("xmlns".utf8) || attribute.starts(with: "xmlns:".utf8) {
                    defaults.append(Default(name: attribute, value: defaultValue, namespace: number(of: defaultValue)))
                } else if attribute.dropFirst().contains(colon), attribute.first != colon {
                    // libxml2 reads a name that starts with a colon as one without a prefix.
                    defaults.append(Default(name: attribute, value: defaultValue))
                }
            }
            var line = Array("<!ATTLIST ".utf8) + element
            line += [space] + attribute
            line += [space] + typeText
            line += [space] + defaultText
            line.append(greaterThan)
            try appendLine(line, to: &subset)
        }
        index += 1
        declaredAttributes[element] = declared
        // Start tags look up only elements that have these.
        if !types.isEmpty {
            attributeTypes[element] = types
        }
        if !defaults.isEmpty {
            attributeDefaults[element] = defaults
        }
        firstDefaults[element] = first
        if hasID {
            elementsWithID.insert(element)
        }
    }

    /// Reads an attribute's type, and returns it with how XMLDocument writes it.
    mutating func readAttributeType() throws -> (AttributeType, [UInt8]) {
        let keywords: [(StaticString, AttributeType)] = [
            ("CDATA", .cdata), ("IDREFS", .idrefs), ("IDREF", .idref), ("ID", .id), ("ENTITY", .entity),
            ("ENTITIES", .entities), ("NMTOKENS", .nmtokens), ("NMTOKEN", .nmtoken),
        ]
        for (keyword, type) in keywords where starts(with: keyword) {
            index += keyword.utf8CodeUnitCount
            return (type, keyword.withUTF8Buffer { Array($0) })
        }
        var isNotation = false
        if starts(with: "NOTATION") {
            index += 8
            guard skipSpaces() else { throw Malformed() }
            isNotation = true
        }
        try expect(leftParenthesis)
        var values: [UInt8] = [leftParenthesis]
        var seen: Set<ArraySlice<UInt8>> = []
        while true {
            skipSpaces()
            let value = try isNotation ? readName() : readNameToken()
            // XMLDocument fails on a value listed twice.
            guard seen.insert(bytes[value]).inserted else { throw Malformed() }
            if values.count > 1 {
                values.append(pipe)
            }
            values += bytes[value]
            skipSpaces()
            guard peek() == pipe else { break }
            index += 1
        }
        try expect(rightParenthesis)
        values.append(rightParenthesis)
        // XMLDocument writes a notation type without its names.
        return isNotation ? (.notation, Array("NOTATION".utf8)) : (.enumeration, values)
    }

    func isValid(_ value: [UInt8], for type: AttributeType) -> Bool {
        switch type {
        case .cdata:
            return true
        case .id, .idref, .entity, .notation:
            return isName(value[...])
        case .idrefs, .entities:
            return value.split(separator: space, omittingEmptySubsequences: false).allSatisfy(isName)
        case .nmtoken:
            return isNameToken(value[...])
        case .nmtokens, .enumeration:
            // libxml2 lets these start with any whitespace, which only a character reference can
            // leave there.
            return value.drop(while: isSpace).split(separator: space, omittingEmptySubsequences: false)
                .allSatisfy(isNameToken)
        }
    }

    // MARK: Entities and notations

    mutating func readEntityDeclaration(into line: inout [UInt8]) throws {
        index += 8
        guard skipSpaces() else { throw Malformed() }
        var isParameter = false
        if peek() == percent {
            index += 1
            guard skipSpaces() else { throw Malformed() }
            isParameter = true
        }
        let name = Array(bytes[try readName()])
        // Colons in an entity's name are a namespace error.
        guard !name.contains(colon) else { throw Malformed() }
        guard skipSpaces() else { throw Malformed() }
        var entity = Entity(kind: .external, isFromParameterEntity: parameterExpansions > 0)
        if peek() == quote || peek() == apostrophe {
            let replacement = try readEntityValue()
            entity.kind = .text(replacement)
            line = Array("<!ENTITY ".utf8) + (isParameter ? [percent, space] : []) + name
            line += Array(" \"".utf8) + replacement + [quote]
        } else {
            // XMLDocument writes an external parameter entity without its `%`.
            line = Array("<!ENTITY ".utf8) + name + [space]
            var hasPublicID = false
            if starts(with: "SYSTEM") {
                index += 6
                guard skipSpaces() else { throw Malformed() }
                line += Array("SYSTEM ".utf8)
            } else if starts(with: "PUBLIC") {
                index += 6
                guard skipSpaces() else { throw Malformed() }
                line += Array("PUBLIC \"".utf8) + bytes[try readPublicID()] + Array("\" ".utf8)
                guard skipSpaces() else { throw Malformed() }
                hasPublicID = true
            } else {
                throw Malformed()
            }
            let system = try readQuoted()
            // A fragment is an error, and XMLDocument fails on what isn't a URI.
            guard isURIReference(Array(bytes[system]), allowsFragment: false) else { throw Malformed() }
            if !hasPublicID, system.isEmpty {
                entity.kind = .externalWithoutSystemID
            }
            line += [quote] + bytes[system] + [quote]
            let spaced = skipSpaces()
            if !isParameter, starts(with: "NDATA") {
                guard spaced else { throw Malformed() }
                index += 5
                guard skipSpaces() else { throw Malformed() }
                entity.kind = .unparsed
                // libxml2 lets the notation's name be left out, and XMLDocument then writes no NDATA.
                if peek() != greaterThan {
                    line += Array(" NDATA ".utf8) + bytes[try readName()]
                }
            } else {
                guard spaced || peek() == greaterThan else { throw Malformed() }
            }
        }
        skipSpaces()
        try expect(greaterThan)
        line.append(greaterThan)
        // The first declaration counts. The predefined entities keep their meaning, and XMLDocument
        // writes them only when they're declared as XML allows.
        var counts: Bool
        if isParameter {
            counts = parameterEntities[name] == nil
            if counts {
                parameterEntities[name] = entity
            }
        } else {
            counts = generalEntities[name] == nil
            if counts, let character = predefinedEntity(name[...]) {
                if case .text(let replacement) = entity.kind {
                    counts = isRedeclaration(replacement, of: character)
                } else {
                    counts = false
                }
            }
            if counts {
                generalEntities[name] = entity
            }
        }
        if !counts {
            line = []
        }
    }

    /// Reads an entity's quoted value, with character references replaced and entity references
    /// kept for when it's used, as XML stores it.
    mutating func readEntityValue() throws -> [UInt8] {
        let delimiter = peek()
        index += 1
        var value: [UInt8] = []
        while true {
            guard index < bytes.count else { throw Malformed() }
            let unit = bytes[index]
            if unit == delimiter {
                index += 1
                return value
            }
            switch unit {
            case percent:
                // Parameter entities can't be used inside declarations here.
                throw Malformed()
            case ampersand:
                if peek(1) == hash {
                    appendUTF8(try readCharacterReference(), to: &value)
                } else {
                    let start = index
                    index += 1
                    _ = try readName()
                    try expect(semicolon)
                    value += bytes[start..<index]
                }
            default:
                value.append(unit)
                index += 1
            }
        }
    }

    /// Whether a predefined entity is declared as XML allows: as its character, or a reference to
    /// it, as libxml2 checks.
    func isRedeclaration(_ replacement: [UInt8], of character: UInt8) -> Bool {
        if replacement == [character], character == greaterThan || character == quote || character == apostrophe {
            return true
        }
        if replacement == Array("&#\(character);".utf8) {
            return true
        }
        let hex = Array("&#x\(String(character, radix: 16));".utf8)
        return replacement.count == hex.count && replacement.starts(with: "&#x".utf8)
            && zip(replacement, hex).allSatisfy { $0 == $1 || $0 | 0x20 == $1 }
    }

    mutating func readNotationDeclaration() throws {
        index += 10
        guard skipSpaces() else { throw Malformed() }
        let name = try readName()
        guard !bytes[name].contains(colon), skipSpaces() else { throw Malformed() }
        if starts(with: "SYSTEM") {
            index += 6
            guard skipSpaces() else { throw Malformed() }
            _ = try readQuoted()
        } else if starts(with: "PUBLIC") {
            index += 6
            guard skipSpaces() else { throw Malformed() }
            _ = try readPublicID()
            // A notation's system ID is optional.
            if skipSpaces(), peek() == quote || peek() == apostrophe {
                _ = try readQuoted()
            }
        }
        skipSpaces()
        try expect(greaterThan)
    }
}

/// An element's content model, as libxml2 builds it from a declaration.
private struct ContentModel {
    static let deepestGroup = 128

    struct Particle {
        enum Kind {
            /// `#PCDATA`.
            case text
            case element, sequence, choice
        }

        var kind: Kind
        var name: [UInt8] = []
        /// `?`, `*`, `+`, or 0 for once.
        var occurrence: UInt8 = 0
        var first = -1
        var second = -1
    }

    var particles: [Particle] = []

    mutating func add(_ particle: Particle) -> Int {
        particles.append(particle)
        return particles.count - 1
    }

    /// Marks a group as repeated the way libxml2 does, which turns `(a | b*)*` into `(a | b)*`.
    /// For `+`, it looks only from the group's last pair on, as libxml2 does.
    mutating func repeatGroup(_ group: Int, last: Int, by occurrence: UInt8) {
        let current = particles[group].occurrence
        let repeats = current == plus || current == star
        switch occurrence {
        case question:
            particles[group].occurrence = repeats ? star : question
        case star:
            particles[group].occurrence = star
            _ = dropOptionalChoices(from: group)
        case plus:
            let optional = current == question || current == star
            particles[group].occurrence = optional ? star : plus
            if dropOptionalChoices(from: last) {
                particles[group].occurrence = star
            }
        default:
            break
        }
    }

    /// Makes the choices in a chain of choices once each, and says whether any wasn't.
    mutating func dropOptionalChoices(from start: Int) -> Bool {
        var found = false
        var node = start
        while node != -1, particles[node].kind == .choice {
            for child in [particles[node].first, particles[node].second] where child != -1 {
                if particles[child].occurrence == question || particles[child].occurrence == star {
                    particles[child].occurrence = 0
                    found = true
                }
            }
            node = particles[node].second
        }
        return found
    }

    /// Writes the model as XMLDocument does: in parentheses, with a list's pairs joined.
    func write(_ root: Int, into line: inout [UInt8]) {
        enum Step {
            case unit(UInt8)
            case occurrence(Int)
            /// What's inside a particle's parentheses.
            case inside(Int)
            /// A particle in a list of the given kind.
            case member(Int, Particle.Kind)
        }
        line.append(leftParenthesis)
        var steps: [Step] = [.occurrence(root), .unit(rightParenthesis), .inside(root)]
        while let step = steps.popLast() {
            switch step {
            case .unit(let unit):
                line.append(unit)
            case .occurrence(let node):
                if particles[node].occurrence != 0 {
                    line.append(particles[node].occurrence)
                }
            case .inside(let node):
                let particle = particles[node]
                switch particle.kind {
                case .text:
                    line += Array("#PCDATA".utf8)
                case .element:
                    line += particle.name
                case .sequence, .choice:
                    steps.append(.member(particle.second, particle.kind))
                    if particle.kind == .sequence {
                        steps += [.unit(space), .unit(comma)]
                    } else {
                        steps += [.unit(space), .unit(pipe), .unit(space)]
                    }
                    steps.append(.member(particle.first, particle.kind))
                }
            case .member(let node, let kind):
                let particle = particles[node]
                if particle.kind == .text || particle.kind == .element {
                    steps += [.occurrence(node), .inside(node)]
                } else if particle.kind == kind, particle.occurrence == 0 {
                    steps.append(.inside(node))
                } else {
                    line.append(leftParenthesis)
                    steps += [.occurrence(node), .unit(rightParenthesis), .inside(node)]
                }
            }
        }
    }
}

// MARK: - Characters

private let tab: UInt8 = 0x09
private let lf: UInt8 = 0x0A
private let cr: UInt8 = 0x0D
private let space: UInt8 = 0x20
private let exclamation = UInt8(ascii: "!")
private let quote = UInt8(ascii: "\"")
private let hash = UInt8(ascii: "#")
private let percent = UInt8(ascii: "%")
private let ampersand = UInt8(ascii: "&")
private let apostrophe = UInt8(ascii: "'")
private let leftParenthesis = UInt8(ascii: "(")
private let rightParenthesis = UInt8(ascii: ")")
private let star = UInt8(ascii: "*")
private let plus = UInt8(ascii: "+")
private let comma = UInt8(ascii: ",")
private let minus = UInt8(ascii: "-")
private let dot = UInt8(ascii: ".")
private let slash = UInt8(ascii: "/")
private let colon = UInt8(ascii: ":")
private let semicolon = UInt8(ascii: ";")
private let lessThan = UInt8(ascii: "<")
private let equals = UInt8(ascii: "=")
private let greaterThan = UInt8(ascii: ">")
private let question = UInt8(ascii: "?")
private let leftBracket = UInt8(ascii: "[")
private let rightBracket = UInt8(ascii: "]")
private let underscore = UInt8(ascii: "_")
private let pipe = UInt8(ascii: "|")

private let escapedAmpersand = Array("&amp;".utf8)
private let escapedLessThan = Array("&lt;".utf8)
private let escapedGreaterThan = Array("&gt;".utf8)
private let escapedQuote = Array("&quot;".utf8)
private let xmlNamespace = Array("http://www.w3.org/XML/1998/namespace".utf8)
private let xmlnsNamespace = Array("http://www.w3.org/2000/xmlns/".utf8)
private let xhtmlNamespace = Array("http://www.w3.org/1999/xhtml".utf8)

/// How the DTDs that make XMLDocument write a document as XHTML start.
private let xhtmlSystemID = Array("http://www.w3.org/TR/xhtml1/DTD/xhtml1".utf8)

/// The elements HTML writes without content or an end tag.
private let voidElements: Set<[UInt8]> = Set(
    ["area", "base", "basefont", "br", "col", "frame", "hr", "img", "input", "isindex", "link", "meta", "param"]
        .map { Array($0.utf8) })

/// The attributes HTML writes by their names alone.
private let booleanAttributes: Set<[UInt8]> = Set(
    [
        "checked", "compact", "declare", "defer", "disabled", "ismap", "multiple", "nohref", "noresize", "noshade",
        "nowrap", "readonly", "selected",
    ]
    .map { Array($0.utf8) })

private func lowercasedASCII(_ units: ArraySlice<UInt8>) -> [UInt8] {
    units.map { isLetter($0) ? $0 | 0x20 : $0 }
}

private func isSpace(_ unit: UInt8) -> Bool {
    unit == space || unit == lf || unit == tab || unit == cr
}

private func isDigit(_ unit: UInt8) -> Bool {
    (0x30...0x39).contains(unit)
}

private func isLetter(_ unit: UInt8) -> Bool {
    (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
}

private func hexValue(_ unit: UInt8) -> UInt32? {
    switch unit {
    case 0x30...0x39: UInt32(unit - 0x30)
    case 0x41...0x46: UInt32(unit - 0x41 + 10)
    case 0x61...0x66: UInt32(unit - 0x61 + 10)
    default: nil
    }
}

/// The characters XML allows.
private func isCharacter(_ value: UInt32) -> Bool {
    switch value {
    case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x1_0000...0x10_FFFF: true
    default: false
    }
}

/// The characters a name can start with, as XML 1.0's fifth edition has them.
private func isNameStart(_ value: UInt32) -> Bool {
    switch value {
    case 0x3A, 0x41...0x5A, 0x5F, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2FF, 0x370...0x37D,
        0x37F...0x1FFF, 0x200C...0x200D, 0x2070...0x218F, 0x2C00...0x2FEF, 0x3001...0xD7FF, 0xF900...0xFDCF,
        0xFDF0...0xFFFD, 0x1_0000...0xE_FFFF:
        true
    default:
        false
    }
}

private func isNameCharacter(_ value: UInt32) -> Bool {
    switch value {
    case 0x2D, 0x2E, 0x30...0x39, 0xB7, 0x300...0x36F, 0x203F...0x2040: true
    default: isNameStart(value)
    }
}

private func isASCIINameCharacter(_ unit: UInt8) -> Bool {
    isLetter(unit) || isDigit(unit) || unit == minus || unit == dot || unit == underscore || unit == colon
}

private func isPublicIDCharacter(_ unit: UInt8) -> Bool {
    isLetter(unit) || isDigit(unit) || unit == space || unit == lf || unit == cr
        || "-'()+,./:=?;!*#@$_%".utf8.contains(unit)
}

/// The character `&name;` stands for, when it's one of XML's five.
private func predefinedEntity(_ name: ArraySlice<UInt8>) -> UInt8? {
    if name.elementsEqual("lt".utf8) { return lessThan }
    if name.elementsEqual("gt".utf8) { return greaterThan }
    if name.elementsEqual("amp".utf8) { return ampersand }
    if name.elementsEqual("quot".utf8) { return quote }
    if name.elementsEqual("apos".utf8) { return apostrophe }
    return nil
}

/// Whether the bytes, all of them, are a name.
private func isName(_ units: ArraySlice<UInt8>) -> Bool {
    var reader = NameReader(units)
    return reader.readName() && reader.isAtEnd
}

private func isNameToken(_ units: ArraySlice<UInt8>) -> Bool {
    var reader = NameReader(units)
    return reader.readNameCharacters() > 0 && reader.isAtEnd
}

/// Whether libxml2 can split a name in a declaration at its first colon: what follows must start
/// as a name does, unless it's nothing at all, or the name starts with the colon.
private func splitsAtPrefix(_ name: [UInt8]) -> Bool {
    guard name.first != colon, let separator = name.firstIndex(of: colon) else { return true }
    let rest = name[(separator + 1)...]
    guard let first = rest.first else { return true }
    if first < 0x80 {
        return isLetter(first) || first == underscore || first == colon
    }
    var reader = NameReader(rest)
    return reader.readName()
}

/// Whether a name has namespaces' form: a name without colons, or two joined by one.
private func isQualifiedName(_ units: ArraySlice<UInt8>) -> Bool {
    guard let separator = units.firstIndex(of: colon) else { return true }
    let local = units[(separator + 1)...]
    guard separator > units.startIndex, let first = local.first, !local.contains(colon) else { return false }
    // The name's characters were checked already, which leaves where its second part starts.
    if first < 0x80 {
        return isNameStart(UInt32(first))
    }
    var reader = NameReader(local)
    return reader.readName()
}

private struct NameReader {
    let units: ArraySlice<UInt8>
    var index: Int

    init(_ units: ArraySlice<UInt8>) {
        self.units = units
        index = units.startIndex
    }

    var isAtEnd: Bool { index == units.endIndex }

    mutating func scalar() -> (value: UInt32, length: Int) {
        var iterator = units[index...].makeIterator()
        var decoder = UTF8()
        guard case .scalarValue(let scalar) = decoder.decode(&iterator) else { return (0, 1) }
        return (scalar.value, scalar.utf8.count)
    }

    mutating func readName() -> Bool {
        guard !isAtEnd else { return false }
        let (first, length) = scalar()
        guard isNameStart(first) else { return false }
        index += length
        readNameCharacters()
        return true
    }

    @discardableResult
    mutating func readNameCharacters() -> Int {
        let start = index
        while !isAtEnd {
            let (value, length) = scalar()
            guard isNameCharacter(value) else { break }
            index += length
        }
        return index - start
    }
}

/// `units` without the bytes at `positions`, which go up, copied once.
private func removing(_ positions: [Int], from units: [UInt8]) -> [UInt8] {
    guard !positions.isEmpty else { return units }
    var kept: [UInt8] = []
    kept.reserveCapacity(units.count - positions.count)
    var start = 0
    for position in positions {
        kept += units[start..<position]
        start = position + 1
    }
    kept += units[start...]
    return kept
}

/// Spaces dropped from the ends, and runs of them made one, as XML normalizes values that aren't
/// CDATA.
private func collapsingSpaces(_ units: ArraySlice<UInt8>) -> [UInt8] {
    var collapsed: [UInt8] = []
    collapsed.reserveCapacity(units.count)
    for unit in units {
        if unit == space, collapsed.last == space || collapsed.isEmpty {
            continue
        }
        collapsed.append(unit)
    }
    if collapsed.last == space {
        collapsed.removeLast()
    }
    return collapsed
}

private func appendUTF8(_ value: UInt32, to units: inout [UInt8]) {
    switch value {
    case ..<0x80:
        units.append(UInt8(value))
    case ..<0x800:
        units += [UInt8(0xC0 | value >> 6), UInt8(0x80 | value & 0x3F)]
    case ..<0x1_0000:
        units += [UInt8(0xE0 | value >> 12), UInt8(0x80 | value >> 6 & 0x3F), UInt8(0x80 | value & 0x3F)]
    default:
        units += [
            UInt8(0xF0 | value >> 18), UInt8(0x80 | value >> 12 & 0x3F), UInt8(0x80 | value >> 6 & 0x3F),
            UInt8(0x80 | value & 0x3F),
        ]
    }
}

// MARK: - URIs

/// Whether `uri` is a URI reference by RFC 3986, read as libxml2 reads one, which XMLDocument
/// requires of namespaces and entities' system IDs. An entity's may not have a fragment.
private func isURIReference(_ uri: [UInt8], allowsFragment: Bool = true) -> Bool {
    var absolute = URIReader(uri)
    if absolute.readAbsolute() {
        return allowsFragment || !absolute.hasFragment
    }
    var relative = URIReader(uri)
    return relative.readRelative() && (allowsFragment || !relative.hasFragment)
}

private struct URIReader {
    let units: [UInt8]
    var index = 0
    /// Whether it has a `#` that starts a fragment, rather than one inside an address's brackets.
    var hasFragment = false

    init(_ units: [UInt8]) {
        self.units = units
    }

    func peek(_ offset: Int = 0) -> UInt8 {
        index + offset < units.count ? units[index + offset] : 0
    }

    func isUnreserved(_ unit: UInt8) -> Bool {
        isLetter(unit) || isDigit(unit) || unit == minus || unit == dot || unit == underscore
            || unit == UInt8(ascii: "~")
    }

    func isSubDelimiter(_ unit: UInt8) -> Bool {
        "!$&'()*+,;=".utf8.contains(unit)
    }

    var atPercentEncoded: Bool {
        peek() == percent && hexValue(peek(1)) != nil && hexValue(peek(2)) != nil
    }

    var atPathCharacter: Bool {
        let unit = peek()
        return isUnreserved(unit) || isSubDelimiter(unit) || unit == colon || unit == UInt8(ascii: "@")
            || atPercentEncoded
    }

    mutating func advance() {
        index += peek() == percent ? 3 : 1
    }

    mutating func readAbsolute() -> Bool {
        guard isLetter(peek()) else { return false }
        while isLetter(peek()) || isDigit(peek()) || peek() == plus || peek() == minus || peek() == dot {
            index += 1
        }
        guard peek() == colon else { return false }
        index += 1
        if peek() == slash, peek(1) == slash {
            index += 2
            guard readAuthority() else { return false }
            readPathAfterAuthority()
        } else if peek() == slash {
            readAbsolutePath()
        } else if atPathCharacter {
            readPath(firstSegmentAllowsColon: true)
        }
        return readQueryAndFragment()
    }

    mutating func readRelative() -> Bool {
        if peek() == slash, peek(1) == slash {
            index += 2
            guard readAuthority() else { return false }
            readPathAfterAuthority()
        } else if peek() == slash {
            readAbsolutePath()
        } else if atPathCharacter {
            readPath(firstSegmentAllowsColon: false)
        }
        return readQueryAndFragment()
    }

    mutating func readAuthority() -> Bool {
        let start = index
        while isUnreserved(peek()) || isSubDelimiter(peek()) || peek() == colon || atPercentEncoded {
            advance()
        }
        if peek() == UInt8(ascii: "@") {
            index += 1
        } else {
            index = start
        }
        if peek() == leftBracket {
            // libxml2 takes whatever is between the brackets.
            while index < units.count, peek() != rightBracket {
                index += 1
            }
            guard peek() == rightBracket else { return false }
            index += 1
        } else {
            while isUnreserved(peek()) || isSubDelimiter(peek()) || atPercentEncoded {
                advance()
            }
        }
        if peek() == colon {
            index += 1
            guard isDigit(peek()) else { return false }
            var port = 0
            while isDigit(peek()) {
                port = port * 10 + Int(peek() - UInt8(ascii: "0"))
                guard port <= Int(Int32.max) else { return false }
                index += 1
            }
        }
        return true
    }

    mutating func readSegment(allowsColon: Bool = true) {
        while atPathCharacter, allowsColon || peek() != colon {
            advance()
        }
    }

    mutating func readPathAfterAuthority() {
        while peek() == slash {
            index += 1
            readSegment()
        }
    }

    mutating func readAbsolutePath() {
        index += 1
        guard atPathCharacter else { return }
        readSegment()
        readPathAfterAuthority()
    }

    mutating func readPath(firstSegmentAllowsColon: Bool) {
        readSegment(allowsColon: firstSegmentAllowsColon)
        readPathAfterAuthority()
    }

    mutating func readQueryAndFragment() -> Bool {
        if peek() == question {
            index += 1
            while atPathCharacter || peek() == slash || peek() == question {
                advance()
            }
        }
        if peek() == hash {
            index += 1
            hasFragment = true
            // libxml2 allows brackets in a fragment.
            while atPathCharacter || peek() == slash || peek() == question || peek() == leftBracket
                || peek() == rightBracket
            {
                advance()
            }
        }
        return index == units.count
    }
}
