import Foundation

/// Proxy settings kept in a JSON file instead of the system's own. Test runs of the app use it to
/// go through the proxy switch, restore file and all, without changing the computer's settings.
public struct FileProxySettings<Settings: UserProxySettings>: ProxySettingsStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// A file that isn't there yet holds the system's first settings: no proxy.
    public func read() throws -> Settings {
        guard let data = try? Data(contentsOf: file) else { return Settings.noProxy }
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    public func write(_ settings: Settings) throws {
        try FileReplacement.write(JSONEncoder().encode(settings), to: file)
    }
}
