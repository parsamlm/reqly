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
    /// Where snaps are, `/snap`, which only tests change.
    public var snaps = URL(filePath: "/snap", directoryHint: .isDirectory)
    /// The system's NSS library, which certutil runs with, or `nil` when it isn't found.
    public var systemNSS: URL? = TrustLocations.systemNSSLibrary()

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

    /// The browsers' NSS databases that exist, and that read the trust certutil adds. Chrome uses
    /// `~/.pki/nssdb` when it's there, which an older Electron app may make at any time, and
    /// otherwise the XDG one. Ubuntu's Chromium snap keeps its own, which can't read the others:
    /// see ``chromiumSnapDatabases()``.
    public func browserDatabases() -> [URL] {
        let shared = [home.appending(path: ".pki/nssdb", directoryHint: .isDirectory), newBrowserDatabase]
        let snap = chromiumSnapReadsCertutilTrust ? chromiumSnapDatabases() : []
        return Self.unique(shared.filter(Self.isFolder) + snap)
    }

    /// The Chromium snap's NSS databases that exist, in the home folder snapd gives it: the XDG one
    /// in `~/snap/chromium/current/.local/share/pki/nssdb`, as Chromium 156 makes it, and the one
    /// before Chromium 146, in `.pki/nssdb` there. They're named through the `current` link, so the
    /// record of where the certificate went still finds them after the snap moves to a new
    /// revision, which copies its home folder.
    public func chromiumSnapDatabases() -> [URL] {
        let snapHome = home.appending(path: "snap/chromium/current", directoryHint: .isDirectory)
        let candidates = [
            snapHome.appending(path: ".local/share/pki/nssdb", directoryHint: .isDirectory),
            snapHome.appending(path: ".pki/nssdb", directoryHint: .isDirectory),
        ]
        return Self.unique(candidates.filter(Self.isFolder))
    }

    /// The Chromium snap's databases when it can't read the trust certutil adds, so Reqly leaves
    /// them out of the browsers' place. You import the certificate in Chromium's settings
    /// instead, as Settings › HTTPS says under Not Covered, and Reqly still removes it from them.
    public func chromiumSnapDatabasesOutOfReach() -> [URL] {
        chromiumSnapReadsCertutilTrust ? [] : chromiumSnapDatabases()
    }

    /// Whether the Chromium snap is installed, and can't read the trust certutil adds.
    public var isChromiumSnapOutOfReach: Bool {
        FileManager.default.fileExists(atPath: snaps.appending(path: "chromium").path)
            && !chromiumSnapReadsCertutilTrust
    }

    /// Whether the Chromium snap reads the trust that this computer's certutil adds. NSS 3.117
    /// and later write it as a PKCS #11 3.2 trust object, which an older NSS doesn't read, and the
    /// snap brings an NSS of its own: on Ubuntu 26.04, certutil's is 3.120, and the snap's 3.98,
    /// so the snap lists the certificate without trusting it. True when either NSS isn't found.
    public var chromiumSnapReadsCertutilTrust: Bool {
        let snapNSS = snaps.appending(path: "chromium/current/usr/lib/\(Self.multiarch)/libnss3.so")
        guard let systemNSS, let writesNew = Self.isNSS3117OrLater(systemNSS),
            let readsNew = Self.isNSS3117OrLater(snapNSS)
        else { return true }
        return readsNew || !writesNew
    }

    /// Whether the NSS library at `url` is 3.117 or later, from the version it exports its newest
    /// functions under, `NSS_3.117`, which certutil 3.120 needs. `nil` when it can't be read.
    static func isNSS3117OrLater(_ url: URL) -> Bool? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        // The names of the exported versions come early in the file, before the code.
        guard let start = try? file.read(upToCount: 1 << 20) else { return nil }
        return start.range(of: Data("NSS_3.117".utf8)) != nil
    }

    /// The NSS library certutil loads, `libnss3.so`, in Debian's and Ubuntu's folder for this
    /// computer's architecture.
    static func systemNSSLibrary() -> URL? {
        ["/usr/lib/\(multiarch)/libnss3.so", "/usr/lib64/libnss3.so", "/usr/lib/libnss3.so"].lazy.map {
            URL(filePath: $0)
        }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Debian's name for this computer's architecture, as its library folders have it, such as
    /// `x86_64-linux-gnu`.
    static var multiarch: String {
        #if arch(arm64)
            "aarch64-linux-gnu"
        #else
            "x86_64-linux-gnu"
        #endif
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
