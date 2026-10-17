import Foundation
import ReqlyModel

/// How Reqly's own connections go, saved as JSON so they're there the next time Reqly opens: the
/// upstream proxy without its password, the reverse proxies, and what the app shows of each client
/// certificate. Passwords and private keys are kept apart, where only your user can read them.
public enum ConnectionsFile {
    public struct Contents: Codable, Hashable, Sendable {
        public var version = 1
        /// The upstream proxy, whether or not it's in use. Its password isn't saved here.
        public var upstreamProxy: UpstreamProxy?
        public var usesUpstreamProxy = false
        public var reverseProxies: [ReverseProxy] = []
        public var clientCertificates: [ClientCertificate] = []

        public init(
            upstreamProxy: UpstreamProxy? = nil, usesUpstreamProxy: Bool = false, reverseProxies: [ReverseProxy] = [],
            clientCertificates: [ClientCertificate] = []
        ) {
            self.upstreamProxy = upstreamProxy
            self.usesUpstreamProxy = usesUpstreamProxy
            self.reverseProxies = reverseProxies
            self.clientCertificates = clientCertificates
        }
    }

    public static let unreadable = "Reqly couldn't read its connection settings, so it started without them."

    /// The saved settings, or none if nothing was saved yet, and what went wrong reading them.
    public static func load(from url: URL) -> (contents: Contents, problem: String?) {
        guard let data = try? Data(contentsOf: url) else { return (Contents(), nil) }
        do {
            return (try JSONDecoder().decode(Contents.self, from: data), nil)
        } catch {
            return (Contents(), unreadable)
        }
    }

    public static func save(_ contents: Contents, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileReplacement.write(encoder.encode(contents), to: url)
    }

    /// What to say when the settings couldn't be saved.
    public static func saveProblem(_ error: any Error) -> String {
        "Reqly couldn't save its connection settings: \(error.localizedDescription)"
    }
}
