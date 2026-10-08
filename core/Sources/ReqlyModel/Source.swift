import Foundation

/// What opened a connection to Reqly: an app, or a command-line tool such as curl.
public struct Source: Hashable, Sendable, Codable {
    /// The name to show, such as "Safari" or "curl".
    public var name: String
    /// The app's bundle identifier. Tools have none.
    public var bundleID: String?
    /// Where the app bundle or the tool lives, for its icon.
    public var path: String?

    public init(name: String, bundleID: String? = nil, path: String? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
    }

    /// Whether it's an app, rather than a command-line tool.
    public var isApp: Bool {
        path?.hasSuffix(".app") ?? false
    }
}
