/// An app's desktop entry, the `.desktop` file that names it in your desktop's menus: its name,
/// icon and program. Only what Reqly reads of it.
public struct DesktopEntry: Hashable, Sendable {
    /// The desktop ID: the file's path under its `applications` folder, with slashes as dashes
    /// and without `.desktop`, such as `org.gnome.Calculator` or `firefox_firefox` for a snap.
    public var id: String
    /// Where the file is.
    public var file: String
    /// The name to show, in your language when the entry has it.
    public var name: String
    /// The name in the entry's own language, its plain `Name`.
    public var unlocalizedName: String
    /// An icon theme's name for its icon, such as `org.gnome.Calculator`, or a file's path.
    public var icon: String?
    public var exec: String?
    public var tryExec: String?
    /// The window class its windows have, which X11 and Xwayland use to match them to it.
    public var startupWMClass: String?
    public var categories: [String]
    /// Whether menus leave it out, as they do for helpers that open files or links.
    public var noDisplay: Bool
    /// Whether it's switched off, as if it were deleted. It still hides entries with the same ID
    /// in folders that come later.
    public var hidden: Bool
    /// Whether it runs in a terminal, as command-line programs such as htop do.
    public var runsInTerminal: Bool
    /// The Flatpak it starts, such as `org.mozilla.firefox`.
    public var flatpakID: String?
    /// The snap it starts, such as `firefox`.
    public var snapName: String?
    /// The program its Exec line starts, past `env` and its variables, and past an interpreter to
    /// the script it runs: a full path when it's found on the search path. `nil` for a Flatpak,
    /// which `flatpak run` starts, and for a shell's command line.
    public var program: String?

    /// Whether it's a terminal, which runs the programs you start in it in its own units.
    public var isTerminalEmulator: Bool {
        categories.contains("TerminalEmulator") || SystemdUnit.terminals.contains(id)
    }

    /// Reads a desktop entry, or returns `nil` when it isn't an application's.
    /// - Parameters:
    ///   - locales: Your languages, the most specific first, such as `de_DE` then `de`, for the
    ///     entry's `Name[de_DE]` and `Name[de]`.
    ///   - searchPath: The folders a program without a path is looked for in, as `PATH` lists them.
    public init?(id: String, file: String, contents: String, locales: [String], searchPath: [String]) {
        var values: [String: String] = [:]
        var inEntry = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.drop { $0 == " " || $0 == "\t" }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                // Only the first group's keys count; actions' groups come later.
                if inEntry { break }
                inEntry = line.hasPrefix("[Desktop Entry]")
                continue
            }
            guard inEntry, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmed(of: " \t")
            let value = line[line.index(after: equals)...].trimmed(of: " \t")
            if values[key] == nil {
                values[key] = Self.unescape(value)
            }
        }
        guard values["Type"] == "Application", let plainName = values["Name"] else { return nil }
        self.id = id
        self.file = file
        unlocalizedName = plainName
        name = locales.lazy.compactMap { values["Name[\($0)]"] }.first ?? plainName
        icon = values["Icon"].flatMap { $0.isEmpty ? nil : $0 }
        exec = values["Exec"]
        tryExec = values["TryExec"]
        startupWMClass = values["StartupWMClass"]
        categories = (values["Categories"] ?? "").split(separator: ";").map(String.init)
        noDisplay = values["NoDisplay"] == "true"
        hidden = values["Hidden"] == "true"
        runsInTerminal = values["Terminal"] == "true"
        let arguments = exec.map(Self.arguments(ofExec:)) ?? []
        let started = Self.started(arguments)
        flatpakID = values["X-Flatpak"] ?? started.flatpak
        program = started.program.map { Self.locate($0, in: searchPath) }
        if let snap = values["X-SnapInstanceName"] {
            snapName = snap
        } else if let program, program.hasPrefix("/snap/bin/") {
            // /snap/bin/<snap> or /snap/bin/<snap>.<app>
            snapName = LinuxFile.fileName(program).split(separator: ".").first.map(String.init)
        } else {
            snapName = nil
        }
    }

    /// What an Exec line's arguments start: a program, or a Flatpak.
    static func started(_ arguments: [String]) -> (program: String?, flatpak: String?) {
        var rest = arguments[...]
        // env, its options and its variables come before the program, as snapd writes them.
        if rest.first.map(LinuxFile.fileName) == "env" {
            rest = rest.dropFirst()
            while let next = rest.first, next.hasPrefix("-") || next.contains("=") {
                rest = rest.dropFirst()
                // -u and -C take the next argument.
                if ["-u", "--unset", "-C", "--chdir"].contains(next) {
                    rest = rest.dropFirst()
                }
            }
        }
        guard let first = rest.first else { return (nil, nil) }
        let name = LinuxFile.fileName(first)
        if name == "flatpak" {
            // flatpak run [options] <app ID> [arguments]
            guard let run = rest.firstIndex(of: "run") else { return (nil, nil) }
            return (nil, rest[(run + 1)...].first { !$0.hasPrefix("-") })
        }
        if Processes.isInterpreter(name) {
            // A shell's command line names no one program.
            if rest.dropFirst().first == "-c" {
                return (nil, nil)
            }
            return (rest.dropFirst().first { !$0.hasPrefix("-") }, nil)
        }
        return (first, nil)
    }

    /// A program's full path, from the search path when it has no folder of its own.
    static func locate(_ program: String, in searchPath: [String]) -> String {
        guard !program.contains("/") else { return program }
        return searchPath.lazy.map { $0 + "/" + program }.first(where: LinuxFile.isProgram) ?? program
    }

    /// Splits an Exec line into arguments as the Desktop Entry Specification says: spaces between
    /// them, double quotes around one with spaces, a backslash before `"`, `` ` ``, `$` and `\` in
    /// quotes, and the field codes, such as `%u` for the file or link to open, left out.
    static func arguments(ofExec exec: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var hasArgument = false
        var inQuotes = false
        var characters = exec.makeIterator()
        while let character = characters.next() {
            switch character {
            case "\"":
                inQuotes.toggle()
                hasArgument = true
            case "\\" where inQuotes:
                if let next = characters.next() {
                    current.append(next)
                }
            case " " where !inQuotes, "\t" where !inQuotes:
                if hasArgument {
                    arguments.append(current)
                }
                current = ""
                hasArgument = false
            case "%" where !inQuotes:
                guard let code = characters.next() else { break }
                if code == "%" {
                    current.append("%")
                    hasArgument = true
                }
            default:
                current.append(character)
                hasArgument = true
            }
        }
        if hasArgument {
            arguments.append(current)
        }
        // An argument that was only a field code, such as `%U`, is gone.
        return arguments.filter { !$0.isEmpty }
    }

    /// Turns a value's escapes, `\s`, `\n`, `\t`, `\r` and `\\`, back into what they stand for.
    static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        var characters = value.makeIterator()
        while let character = characters.next() {
            guard character == "\\", let next = characters.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "s": result.append(" ")
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\\": result.append("\\")
            default: result.append(contentsOf: ["\\", next])
            }
        }
        return result
    }
}

extension StringProtocol {
    /// The text without these characters at either end.
    func trimmed(of set: String) -> String {
        let trimmed = drop { set.contains($0) }
        guard let last = trimmed.lastIndex(where: { !set.contains($0) }) else { return "" }
        return String(trimmed[...last])
    }
}
