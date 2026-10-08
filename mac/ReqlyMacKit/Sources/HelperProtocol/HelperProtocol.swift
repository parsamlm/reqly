import Foundation

/// What Reqly can ask ReqlyHelper to do, over XPC. The helper runs as root, so it offers only
/// these two commands and checks every argument.
@objc public protocol ReqlyHelperXPC {
    /// Points the HTTP and HTTPS proxy of every active network service at 127.0.0.1:`port`,
    /// after saving the current settings. The helper puts them back when Reqly asks, when Reqly
    /// quits or crashes, and when the Mac starts up after a capture was left on.
    func setProxy(port: Int, reply: @escaping @Sendable (NSError?) -> Void)

    /// Puts back the settings saved by `setProxy`. Does nothing if nothing was saved.
    func restoreProxy(reply: @escaping @Sendable (NSError?) -> Void)
}

/// Names that tie the app, its helper and the helper's launchd property list together.
public enum HelperNames {
    /// The helper's bundle identifier, which is also its launchd label and Mach service name.
    public static func helperIdentifier(forApp appIdentifier: String) -> String {
        appIdentifier + ".Helper"
    }

    /// The app's bundle identifier, from the helper's.
    public static func appIdentifier(forHelper helperIdentifier: String) -> String? {
        guard helperIdentifier.hasSuffix(".Helper") else { return nil }
        return String(helperIdentifier.dropLast(".Helper".count))
    }

    /// The launchd property list inside the app, in `Contents/Library/LaunchDaemons`.
    public static func launchdPlistName(forApp appIdentifier: String) -> String {
        helperIdentifier(forApp: appIdentifier) + ".plist"
    }
}

/// Errors the helper reports back to the app.
public enum HelperError: Int, Error, CustomNSError {
    case invalidPort = 1
    case cannotReadSettings
    case cannotChangeSettings
    case cannotSaveState

    public static let errorDomain = "net.reqly.helper"

    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: message]
    }

    public var message: String {
        switch self {
        case .invalidPort: "The proxy port must be between 1024 and 65535."
        case .cannotReadSettings: "Reqly couldn't read your network settings."
        case .cannotChangeSettings: "Reqly couldn't change your network settings."
        case .cannotSaveState: "Reqly couldn't save your current proxy settings, so it didn't change them."
        }
    }
}
