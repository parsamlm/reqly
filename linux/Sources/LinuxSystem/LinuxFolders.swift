import Foundation

/// Where Reqly for Linux keeps its files, as the XDG base directories say: your settings in your
/// config folder, what it keeps while it runs in your state folder, and its certificate in your
/// data folder.
public struct LinuxFolders: Sendable {
    /// `~/.config/reqly`: the settings, the rules and the other files Reqly keeps as Windows does,
    /// in the same JSON.
    public var config: URL
    /// `~/.local/state/reqly`: live sessions, crash files and the proxy restore file.
    public var state: URL
    /// `~/.local/share/reqly`: the certificate, and its key and the other secrets when there's
    /// no keyring. Only you can open it.
    public var data: URL

    /// The folders for `environment`, such as the process's own. A variable that's empty or not
    /// an absolute path counts as unset, as the XDG specification says.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = URL(filePath: environment["HOME"] ?? NSHomeDirectory(), directoryHint: .isDirectory)
        func base(_ variable: String, _ fallback: String) -> URL {
            if let path = environment[variable], path.hasPrefix("/") {
                return URL(filePath: path, directoryHint: .isDirectory)
            }
            return home.appending(path: fallback, directoryHint: .isDirectory)
        }
        config = base("XDG_CONFIG_HOME", ".config").appending(path: "reqly", directoryHint: .isDirectory)
        state = base("XDG_STATE_HOME", ".local/state").appending(path: "reqly", directoryHint: .isDirectory)
        data = base("XDG_DATA_HOME", ".local/share").appending(path: "reqly", directoryHint: .isDirectory)
    }

    /// Your proxy settings, kept while Reqly captures, so they come back if it quits
    /// unexpectedly.
    public var proxyRestoreFile: URL { state.appending(path: "ProxyRestore.json") }
    /// Where Reqly's certificate and its key go when there's no keyring to keep the key in, as
    /// `OpenOptions.rootFile`. The certificate's other files go beside it.
    public var rootFile: URL { data.appending(path: "Certificate.dat") }
    /// Where the upstream proxy's password and client certificates' keys go when there's no
    /// keyring to keep them in, as the core's `openConnections` call names it.
    public var secretsFile: URL { data.appending(path: "Secrets.json") }
}
