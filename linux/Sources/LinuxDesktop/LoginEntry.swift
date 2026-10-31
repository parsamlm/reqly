import Foundation
import ReqlyModel

/// The autostart entry Reqly keeps while it captures,
/// `~/.config/autostart/net.reqly.Reqly-restore-proxy.desktop`. GNOME and KDE run it when you
/// log in, so settings that a power cut left pointing at Reqly go back before you open an app.
/// Reqly deletes it when capture stops.
public struct LoginEntry: Sendable {
    /// The entry's file.
    public var file: URL

    /// The entry's file name, after Reqly's app ID.
    public static let fileName = "net.reqly.Reqly-restore-proxy.desktop"

    public init(file: URL) {
        self.file = file
    }

    /// The entry in `XDG_CONFIG_HOME`'s autostart folder, or `~/.config`'s.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? URL.homeDirectory
        let config =
            environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil }
            ?? home.appending(path: ".config", directoryHint: .isDirectory)
        self.init(file: config.appending(path: "autostart", directoryHint: .isDirectory).appending(path: Self.fileName))
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
        try FileReplacement.writeDurably(
            Data(Self.text(executable: executable, restoreFile: restoreFile).utf8), to: file)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: file)
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
