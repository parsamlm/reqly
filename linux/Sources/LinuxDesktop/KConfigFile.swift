/// A file in KDE's KConfig format, such as `kioslaverc`, which Reqly changes one key at a time.
/// Every other line stays as it was, byte for byte: other groups, other keys, comments, blank
/// lines, a key's translations, and Windows line endings. KDE's own tools would rewrite the whole
/// file, and `kwriteconfig6` isn't always installed.
///
/// The format: `[Group]` lines start groups, `[Group][Subgroup]` nested ones, and `key=value`
/// lines set keys, with spaces around either side ignored. `#` starts a comment. `key[de]=…` is a
/// translation, and `key[$i]=…` or `[Group][$i]` locks a key or group, as `[$i]` alone does the
/// file. Values escape a backslash, a line break, a tab and spaces at either end.
public struct KConfigFile: Hashable, Sendable {
    /// The file's lines, each without its `\n`. A file with Windows line endings keeps each `\r`.
    private var lines: [String]
    /// Whether the last line ends with a line break, as files usually do.
    private var endsWithNewline: Bool

    /// The file holding `text`, which can be empty, as for a file that isn't there yet. Text that
    /// came from bytes that aren't UTF-8 wouldn't be written back the same, so callers check.
    public init(text: String) {
        // By bytes, since Swift's characters take `\r\n` as one.
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        endsWithNewline = lines.last == ""
        if endsWithNewline {
            lines.removeLast()
        }
        self.lines = lines
    }

    /// The file's text.
    public var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }

    /// Whether no key is left, in any group.
    public var hasNoKeys: Bool {
        parsed.allSatisfy { if case .entry = $0.kind { false } else { true } }
    }

    /// The value of `key` in `group`, the last one when it's there more than once, as KDE reads
    /// it. Translations don't count.
    public func value(_ key: String, in group: [String]) -> String? {
        guard let last = entries(key, in: group).last, case .entry(_, _, let value) = parsed[last].kind else {
            return nil
        }
        return Self.unescaped(value)
    }

    /// Whether this file locks `key` in `group`: the whole file, the group, or the key.
    public func isLocked(_ key: String, in group: [String]) -> Bool {
        for line in parsed {
            switch line.kind {
            case .fileLock: return true
            case .group(let name, let locked) where locked && Self.group(name, isWithin: group): return true
            case .entry(let name, let options, _) where name == key && line.group == group && options.contains("$i"):
                return true
            default: continue
            }
        }
        return false
    }

    /// Sets `key` in `group` to `value`: in place of the key's last line, with the earlier ones,
    /// which KDE ignores, removed. A new key goes after the group's last key, and a new group at
    /// the end of the file, after a blank line.
    public mutating func setValue(_ value: String, for key: String, in group: [String]) {
        let line = "\(key)=\(Self.escaped(value))" + lineEnding
        let found = entries(key, in: group)
        if let last = found.last {
            lines[last] = line
            for index in found.dropLast().reversed() {
                lines.remove(at: index)
            }
            return
        }
        let parsed = parsed
        if let header = parsed.lastIndex(where: { $0.isHeader(of: group) }) {
            var end = header
            for index in parsed.indices.dropFirst(header + 1) {
                if case .group = parsed[index].kind { break }
                if case .fileLock = parsed[index].kind { break }
                if case .blank = parsed[index].kind { continue }
                end = index
            }
            insert(line, at: end + 1)
            return
        }
        if group.isEmpty {
            // Keys outside any group go before the first one.
            let first = parsed.firstIndex(where: { $0.isAnyHeader }) ?? lines.count
            insert(line, at: first)
            return
        }
        if !lines.isEmpty {
            insert(lineEnding, at: lines.count)
        }
        insert(group.map { "[\($0)]" }.joined() + lineEnding, at: lines.count)
        insert(line, at: lines.count)
    }

    /// Removes `key` from `group`, all of its lines, but not its translations. A group left with
    /// nothing in it goes too, and at the end of the file, so does the blank line before it.
    public mutating func removeValue(_ key: String, in group: [String]) {
        let found = entries(key, in: group)
        guard !found.isEmpty else { return }
        for index in found.reversed() {
            lines.remove(at: index)
        }
        let parsed = parsed
        for header in parsed.indices.reversed() where parsed[header].isHeader(of: group) {
            var end = header + 1
            while end < parsed.count, case .blank = parsed[end].kind {
                end += 1
            }
            guard end == parsed.count || parsed[end].isAnyHeader else { continue }
            var start = header
            if end == parsed.count, start > 0, case .blank = parsed[start - 1].kind {
                start -= 1
            }
            lines.removeSubrange(start..<end)
            if lines.isEmpty {
                endsWithNewline = false
            }
        }
    }

    // MARK: - Reading lines

    private struct Line {
        enum Kind {
            case blank
            case comment
            /// `[$i]` before any group, which locks the whole file.
            case fileLock
            /// A group's header: its name, each part one bracket's, and whether `[$i]` locks it.
            case group([String], locked: Bool)
            /// A key, its options, such as `$i`, and its value as written. Translations aren't.
            case entry(String, options: [String], value: Substring)
            /// A translation, or a line KDE skips.
            case other
        }

        var kind: Kind
        /// The group the line is in.
        var group: [String]

        var isAnyHeader: Bool {
            switch kind {
            case .group, .fileLock: true
            default: false
            }
        }

        func isHeader(of group: [String]) -> Bool {
            if case .group(let name, _) = kind { name == group } else { false }
        }
    }

    /// Each line, read.
    private var parsed: [Line] {
        var group: [String] = []
        var seenGroup = false
        return lines.map { raw in
            let line = raw.drop { $0 == " " || $0 == "\t" }.trimmingTrailingWhitespace
            if line.isEmpty {
                return Line(kind: .blank, group: group)
            }
            if line.hasPrefix("#") {
                return Line(kind: .comment, group: group)
            }
            if line.hasPrefix("[") {
                let parts = Self.bracketed(line)
                if parts == ["$i"] && !seenGroup {
                    return Line(kind: .fileLock, group: group)
                }
                seenGroup = true
                let locked = parts.last == "$i"
                group = locked ? Array(parts.dropLast()) : parts
                return Line(kind: .group(group, locked: locked), group: group)
            }
            guard let equals = line.firstIndex(of: "=") else { return Line(kind: .other, group: group) }
            let name = line[..<equals].trimmingTrailingWhitespace
            let value = line[line.index(after: equals)...].drop { $0 == " " || $0 == "\t" }
            guard let bracket = name.firstIndex(of: "[") else {
                return Line(kind: .entry(String(name), options: [], value: value), group: group)
            }
            let options = Self.bracketed(name[bracket...])
            guard options.allSatisfy({ $0.hasPrefix("$") }) else { return Line(kind: .other, group: group) }
            return Line(kind: .entry(String(name[..<bracket]), options: options, value: value), group: group)
        }
    }

    /// The indexes of `key`'s lines in `group`, first to last.
    private func entries(_ key: String, in group: [String]) -> [Int] {
        let parsed = parsed
        return parsed.indices.filter { index in
            guard case .entry(let name, _, _) = parsed[index].kind else { return false }
            return name == key && parsed[index].group == group
        }
    }

    /// What each bracket in `[a][b]…` holds.
    private static func bracketed(_ text: Substring) -> [String] {
        var parts: [String] = []
        var rest = text
        while rest.first == "[", let close = rest.firstIndex(of: "]") {
            parts.append(String(rest[rest.index(after: rest.startIndex)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return parts
    }

    /// Whether a lock on group `locked` covers `group`: the same group, or one it's inside.
    private static func group(_ locked: [String], isWithin group: [String]) -> Bool {
        group.starts(with: locked)
    }

    /// Windows' line ending when the file's first line has one, and Linux's otherwise.
    private var lineEnding: String { lines.first?.hasSuffix("\r") == true ? "\r" : "" }

    /// Puts `line` in at `index`, which can be the end.
    private mutating func insert(_ line: String, at index: Int) {
        if index == lines.count && !lines.isEmpty && !endsWithNewline {
            endsWithNewline = true
        }
        if lines.isEmpty {
            endsWithNewline = true
        }
        lines.insert(line, at: index)
    }

    // MARK: - Escapes

    /// A value as KDE writes it: backslashes, line breaks, tabs and other control characters
    /// escaped, and a space at either end written as `\s`, so it isn't trimmed.
    static func escaped(_ value: String) -> String {
        var text = ""
        let scalars = Array(value.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch scalar {
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\t": text += "\\t"
            case "\r": text += "\\r"
            case " " where index == 0 || index == scalars.count - 1: text += "\\s"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                text += "\\x" + String(scalar.value, radix: 16).leftPadded(to: 2)
            default: text.unicodeScalars.append(scalar)
            }
        }
        return text
    }

    /// A value as KDE reads it. `\;` and `\,` stay, since they matter only to lists.
    static func unescaped(_ value: Substring) -> String {
        var bytes: [UInt8] = []
        var rest = Array(value.utf8)[...]
        while let byte = rest.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = rest.popFirst() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "s"): bytes.append(UInt8(ascii: " "))
            case UInt8(ascii: "t"): bytes.append(UInt8(ascii: "\t"))
            case UInt8(ascii: "n"): bytes.append(UInt8(ascii: "\n"))
            case UInt8(ascii: "r"): bytes.append(UInt8(ascii: "\r"))
            case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "x") where rest.count >= 2:
                if let code = UInt8(String(decoding: rest.prefix(2), as: UTF8.self), radix: 16) {
                    bytes.append(code)
                    rest = rest.dropFirst(2)
                } else {
                    bytes += [byte, next]
                }
            default: bytes += [byte, next]
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension Substring {
    /// Without spaces, tabs or `\r` at the end.
    fileprivate var trimmingTrailingWhitespace: Substring {
        var text = self
        while let last = text.last, last == " " || last == "\t" || last == "\r" {
            text = text.dropLast()
        }
        return text
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: Swift.max(0, length - count)) + self
    }
}
