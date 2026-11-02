import Foundation
import ReqlyModel

/// The autostart entry Reqly keeps while it captures,
/// `~/.config/autostart/net.reqly.Reqly-restore-proxy.desktop`. GNOME and KDE run it when you
/// log in, so settings that a power cut left pointing at Reqly go back before you open an app.
/// Reqly deletes it when capture stops.
public struct LoginEntry: Sendable {
    /// The entry's file.
    public var file: URL
    /// Where Reqly notes that it made the autostart folder for the entry, so the folder goes
    /// with the entry while nothing else is in it, or `nil` to leave the folder.
    public var folderNote: URL?

    /// The entry's file name, after Reqly's app ID.
    public static let fileName = "net.reqly.Reqly-restore-proxy.desktop"

    public init(file: URL, folderNote: URL? = nil) {
        self.file = file
        self.folderNote = folderNote
    }

    /// The entry in `XDG_CONFIG_HOME`'s autostart folder, or `~/.config`'s, with its folder's
    /// note in Reqly's folder in `XDG_STATE_HOME`, or `~/.local/state`'s.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? URL.homeDirectory
        func base(_ variable: String, _ fallback: String) -> URL {
            environment[variable].flatMap { $0.hasPrefix("/") ? URL(filePath: $0, directoryHint: .isDirectory) : nil }
                ?? home.appending(path: fallback, directoryHint: .isDirectory)
        }
        self.init(
            file: base("XDG_CONFIG_HOME", ".config").appending(path: "autostart", directoryHint: .isDirectory)
                .appending(path: Self.fileName),
            folderNote: base("XDG_STATE_HOME", ".local/state").appending(path: "reqly/MadeAutostartFolder"))
    }

    /// The entry's text: it runs `executable --restore-proxy restoreFile`, and shows nowhere.
    /// `TryExec` skips it once Reqly is uninstalled.
    public static func text(executable: String, restoreFile: URL) -> String {
        """
        [Desktop Entry]
        Type=Application
        Name=Reqly
        Comment=Puts your proxy settings back if Reqly quit while capturing
        TryExec=\(escaped(executable))
        Exec=\(quoted(executable)) --restore-proxy \(quoted(restoreFile.path))
        NoDisplay=true
        X-GNOME-Autostart-enabled=true
        X-GNOME-AutoRestart=false

        """
    }

    /// Writes the entry, and waits until the disk has it, so it's there after a power cut.
    public func write(executable: String, restoreFile: URL) throws {
        let folder = file.deletingLastPathComponent()
        if let folderNote, !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(
                at: folderNote.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: folderNote.path, contents: nil)
        }
        try FileReplacement.writeDurably(
            Data(Self.text(executable: executable, restoreFile: restoreFile).utf8), to: file)
    }

    /// Removes the entry, and the autostart folder when Reqly made it for the entry and nothing
    /// else has gone in since.
    public func remove() {
        try? FileManager.default.removeItem(at: file)
        guard let folderNote, FileManager.default.fileExists(atPath: folderNote.path) else { return }
        // Only an empty folder goes. One with entries of yours in it is yours from now on.
        rmdir(file.deletingLastPathComponent().path)
        try? FileManager.default.removeItem(at: folderNote)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    // MARK: - Desktop entries' quoting

    /// An argument for `Exec`, in double quotes, as the Desktop Entry Specification says: `"`,
    /// `` ` ``, `$` and `\` take a backslash, `%` is doubled, and then the whole is escaped as
    /// any value is.
    static func quoted(_ argument: String) -> String {
        var text = "\""
        for character in argument {
            switch character {
            case "\"", "`", "$", "\\": text += "\\\(character)"
            case "%": text += "%%"
            default: text.append(character)
            }
        }
        return escaped(text + "\"")
    }

    /// A value as desktop entries escape it: a backslash, a line break, a tab and a return.
    static func escaped(_ value: String) -> String {
        var text = ""
        for character in value {
            switch character {
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\t": text += "\\t"
            case "\r": text += "\\r"
            default: text.append(character)
            }
        }
        return text
    }
}
