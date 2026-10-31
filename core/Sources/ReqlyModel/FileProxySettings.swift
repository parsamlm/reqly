import Foundation

/// Proxy settings kept in a JSON file instead of the system's own. Test runs of the app use it to
/// go through the proxy switch, restore file and all, without changing the computer's settings.
public struct FileProxySettings<Settings: UserProxySettings>: ProxySettingsStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// The file couldn't be written. Foundation's own description of a file error says nothing on
    /// Linux, so this one names the file.
    public struct WriteFailure: LocalizedError, Equatable {
        public var file: URL

        public var errorDescription: String? {
            let path = file.withUnsafeFileSystemRepresentation { String(cString: $0!) }
            return "Reqly couldn't write the stand-in for the proxy settings, \(path)."
        }
    }

    /// A file that isn't there yet holds the system's first settings: no proxy.
    public func read() throws -> Settings {
        guard let data = try? Data(contentsOf: file) else { return Settings.noProxy }
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    public func write(_ settings: Settings) throws {
        let data = try JSONEncoder().encode(settings)
        do {
            try FileReplacement.write(data, to: file)
        } catch {
            throw WriteFailure(file: file)
        }
    }
}
