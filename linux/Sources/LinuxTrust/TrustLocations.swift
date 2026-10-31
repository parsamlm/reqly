import Foundation

/// Where your browsers keep the certificates they trust, in your home folder: the NSS databases
/// that Chrome and browsers built on it share, and Firefox's profiles. Finding them reads a few
/// files and runs nothing.
public struct TrustLocations: Sendable {
    public var home: URL
    /// `XDG_DATA_HOME`, or `~/.local/share`.
    public var dataHome: URL
    /// `XDG_CONFIG_HOME`, or `~/.config`.
    public var configHome: URL

    /// The locations for `environment`, such as the process's own. A variable that's empty or
    /// not an absolute path counts as unset, as the XDG specification says.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = URL(filePath: environment["HOME"] ?? NSHomeDirectory(), directoryHint: .isDirectory)
        func base(_ variable: String, _ fallback: String) -> URL {
            if let path = environment[variable], path.hasPrefix("/") {
                return URL(filePath: path, directoryHint: .isDirectory)
            }
            return home.appending(path: fallback, directoryHint: .isDirectory)
        }
        self.home = home
        dataHome = base("XDG_DATA_HOME", ".local/share")
        configHome = base("XDG_CONFIG_HOME", ".config")
    }

    /// The database Chrome makes when there's none, since version 146: `~/.local/share/pki/nssdb`.
    /// Reqly never makes one: it adds to those it finds.
    public var newBrowserDatabase: URL {
        dataHome.appending(path: "pki/nssdb", directoryHint: .isDirectory)
    }

    /// The browsers' NSS databases that exist. Chrome uses `~/.pki/nssdb` when it's there, which an
    /// older Electron app may make at any time, and otherwise the XDG one. Ubuntu's Chromium snap
    /// keeps its own and can't read the others.
    public func browserDatabases() -> [URL] {
        let candidates = [
            home.appending(path: ".pki/nssdb", directoryHint: .isDirectory),
            newBrowserDatabase,
            home.appending(path: "snap/chromium/current/.pki/nssdb", directoryHint: .isDirectory),
        ]
        return Self.unique(candidates.filter(Self.isFolder))
    }

    /// The folders that may hold Firefox's profiles.ini: Firefox's own, its XDG ones (Firefox ESR
    /// 153 makes new profiles in `~/.config/mozilla/firefox`), the snap's (Ubuntu's Firefox), and
    /// the Flatpak's.
    public var firefoxFolders: [URL] {
        let paths = [
            home.appending(path: ".mozilla/firefox"),
            configHome.appending(path: "mozilla/firefox"),
            home.appending(path: ".config/mozilla/firefox"),
            dataHome.appending(path: "mozilla/firefox"),
            home.appending(path: ".local/share/mozilla/firefox"),
            home.appending(path: "snap/firefox/common/.mozilla/firefox"),
            // Where the snap would follow the move to ~/.config: its own choice, or snapd's
            // XDG_CONFIG_HOME for it. Neither seen yet.
            home.appending(path: "snap/firefox/common/.config/mozilla/firefox"),
            home.appending(path: "snap/firefox/current/.config/mozilla/firefox"),
            home.appending(path: ".var/app/org.mozilla.firefox/.mozilla/firefox"),
            // The Flatpak's XDG_CONFIG_HOME, where it would make new profiles after the move.
            home.appending(path: ".var/app/org.mozilla.firefox/config/mozilla/firefox"),
        ]
        return Self.unique(paths.map { URL(filePath: $0.path, directoryHint: .isDirectory) })
    }

    /// Firefox's profiles that have a certificate database. A profile without one hasn't been
    /// opened yet, and Firefox makes it the first time.
    public func firefoxProfiles() -> [URL] {
        var profiles: [URL] = []
        for folder in firefoxFolders {
            guard let text = try? String(contentsOf: folder.appending(path: "profiles.ini"), encoding: .utf8) else {
                continue
            }
            profiles += Self.profiles(in: text, folder: folder).filter {
                FileManager.default.fileExists(atPath: $0.appending(path: "cert9.db").path)
            }
        }
        return Self.unique(profiles)
    }

    /// The profile folders that profiles.ini in `folder` lists, from each `[Profile…]` section's
    /// `Path=`, which is relative to `folder` unless `IsRelative=0`.
    static func profiles(in text: String, folder: URL) -> [URL] {
        var found: [URL] = []
        var section = ""
        var path: String?
        var isRelative = true
        func finish() {
            if section.hasPrefix("Profile"), let path, !path.isEmpty {
                let url =
                    isRelative && !path.hasPrefix("/")
                    ? folder.appending(path: path, directoryHint: .isDirectory)
                    : URL(filePath: path, directoryHint: .isDirectory)
                found.append(url.standardizedFileURL)
            }
            path = nil
            isRelative = true
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                finish()
                section = String(line.dropFirst().dropLast())
            } else if let equals = line.firstIndex(of: "=") {
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                switch line[..<equals].trimmingCharacters(in: .whitespaces) {
                case "Path": path = value
                case "IsRelative": isRelative = value != "0"
                default: break
                }
            }
        }
        finish()
        return found
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// `urls` in order, each folder once, however its path is written.
    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.resolvingSymlinksInPath().path
            return seen.insert(path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path).inserted
        }
    }
}
