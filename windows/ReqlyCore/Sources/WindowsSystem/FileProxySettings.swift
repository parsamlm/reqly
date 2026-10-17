import Foundation
import ReqlyModel

/// Proxy settings kept in a JSON file instead of Windows' own. Test runs of the app use it to go
/// through the proxy switch, restore file and all, without changing the computer's settings.
public struct FileProxySettings: ProxySettingsStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// A file that isn't there yet holds Windows' first settings: no proxy.
    public func read() throws -> ProxySettings {
        guard let data = try? Data(contentsOf: file) else { return ProxySettings() }
        return try JSONDecoder().decode(ProxySettings.self, from: data)
    }

    public func write(_ settings: ProxySettings) throws {
        try FileReplacement.write(JSONEncoder().encode(settings), to: file)
    }
}
