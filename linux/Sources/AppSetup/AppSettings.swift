import Foundation
import ReqlyModel

/// Your settings for Reqly, in `Settings.json`, with the Windows app's names
/// (windows/Reqly/Settings/AppSettings.cs). A file that's missing reads as the first settings, and
/// a setting that's missing or can't be read keeps its first value, as from another version or a
/// file edited by hand.
public struct AppSettings: Codable, Equatable, Sendable {
    /// The port Reqly listens on.
    public var proxyPort = 9090
    /// Whether capturing starts when Reqly opens. As on the Mac, it doesn't at first.
    public var startsCapturingOnLaunch = false
    /// The hosts to decrypt, each switched on or off.
    public var decryptedHosts = DecryptedHosts()
    /// Whether the sidebar's Apps, Devices and Hosts show their rows, or are folded away, with the
    /// Mac's names. They show at first.
    public var sidebarShowsApps = true
    public var sidebarShowsDevices = true
    public var sidebarShowsHosts = true
    /// Whether saved sessions leave out authorization headers and cookies. They keep them at first.
    public var hidesSecretsInSessions = false
    /// Whether HAR files leave out authorization headers and cookies, as they do at first, since
    /// they're often shared.
    public var hidesSecretsInHar = true
    /// Whether HAR files have the responses' bodies, as they do at first.
    public var harIncludesResponseBodies = true
    /// Whether phones and tablets on the network may connect, once you let each one in. They can't
    /// at first.
    public var allowsNetworkDevices = false
    /// Whether Welcome to Reqly has opened. It opens once, the first time Reqly does.
    public var hasSeenWelcome = false
    /// The devices folded away in the sidebar, by their rows' keys, each once. Linux's own: Windows
    /// keeps them only while it runs.
    public var sidebarFoldedDevices: [String] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let port = try? container.decodeIfPresent(Int.self, forKey: .proxyPort), (1...65535).contains(port) {
            proxyPort = port
        }
        if let starts = try? container.decodeIfPresent(Bool.self, forKey: .startsCapturingOnLaunch) {
            startsCapturingOnLaunch = starts
        }
        if let hosts = try? container.decodeIfPresent(DecryptedHosts.self, forKey: .decryptedHosts) {
            decryptedHosts = hosts
        }
        if let shows = try? container.decodeIfPresent(Bool.self, forKey: .sidebarShowsApps) {
            sidebarShowsApps = shows
        }
        if let shows = try? container.decodeIfPresent(Bool.self, forKey: .sidebarShowsDevices) {
            sidebarShowsDevices = shows
        }
        if let shows = try? container.decodeIfPresent(Bool.self, forKey: .sidebarShowsHosts) {
            sidebarShowsHosts = shows
        }
        let switches: [(CodingKeys, WritableKeyPath<AppSettings, Bool>)] = [
            (.hidesSecretsInSessions, \.hidesSecretsInSessions), (.hidesSecretsInHar, \.hidesSecretsInHar),
            (.harIncludesResponseBodies, \.harIncludesResponseBodies),
            (.allowsNetworkDevices, \.allowsNetworkDevices), (.hasSeenWelcome, \.hasSeenWelcome),
        ]
        for (key, setting) in switches {
            if let isOn = try? container.decodeIfPresent(Bool.self, forKey: key) {
                self[keyPath: setting] = isOn
            }
        }
        if let folded = try? container.decodeIfPresent([String].self, forKey: .sidebarFoldedDevices) {
            var seen: Set<String> = []
            sidebarFoldedDevices = folded.filter { seen.insert($0).inserted }
        }
    }

    /// The settings in `file`, or the first settings when there's none or it isn't JSON.
    public static func load(from file: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: file) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    /// Saves the settings to `file`, which only you can read, in a new file that then takes the
    /// old one's place, so a crash never leaves half a file. Foundation's atomic write would make
    /// a file everyone can read.
    public func save(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let draft = folder.appending(path: ".\(file.lastPathComponent).\(UUID().uuidString)")
        let fd = open(draft.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Self.failure() }
        var replaced = false
        defer {
            if !replaced { unlink(draft.path) }
        }
        let written = data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, fsync(fd) == 0 else {
            let failure = Self.failure()
            close(fd)
            throw failure
        }
        close(fd)
        guard rename(draft.path, file.path) == 0 else { throw Self.failure() }
        replaced = true
    }

    /// The error `errno` names.
    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
