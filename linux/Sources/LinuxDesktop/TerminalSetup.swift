import Foundation

/// A terminal set up for Reqly: the variables that send command-line tools through it, and make
/// them trust its certificate, as text to paste into a shell or set in a terminal Reqly opens.
/// curl, wget, git, Go, Python and pip read only these, and Node only with
/// `NODE_USE_ENV_PROXY=1`.
public struct TerminalSetup: Hashable, Sendable {
    /// The port Reqly captures on.
    public var port: Int
    /// Reqly's certificate files, once HTTPS is set up.
    public var certificates: Certificates?

    /// Reqly's certificate, as tools read it.
    public struct Certificates: Hashable, Sendable {
        /// The system's certificates with Reqly's added, `ca-certificates.crt`, which LinuxTrust's
        /// root store writes beside the certificate, for tools whose variable replaces their list
        /// rather than adds to it. Reqly passes the hosts it doesn't decrypt through untouched, so
        /// the list can't hold Reqly's certificate alone.
        public var bundle: URL
        /// Reqly's certificate alone, `Reqly CA.pem`, for Node, which adds it to its own list.
        public var root: URL

        public init(bundle: URL, root: URL) {
            self.bundle = bundle
            self.root = root
        }
    }

    public init(port: Int, certificates: Certificates?) {
        self.port = port
        self.certificates = certificates
    }

    /// The proxy variables, in both cases, since curl reads `http_proxy` only in lowercase and
    /// other tools only in capitals. Reqly removes them from its own environment as it starts.
    public static let proxyVariables = [
        "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "no_proxy", "NO_PROXY", "all_proxy", "ALL_PROXY",
    ]

    /// Each variable and its value, in order.
    public var variables: [(name: String, value: String)] {
        let proxy = "http://127.0.0.1:\(port)"
        let direct = "localhost,127.0.0.1,::1"
        var variables = [
            ("http_proxy", proxy), ("https_proxy", proxy), ("HTTP_PROXY", proxy), ("HTTPS_PROXY", proxy),
            ("no_proxy", direct), ("NO_PROXY", direct), ("NODE_USE_ENV_PROXY", "1"),
        ]
        if let certificates {
            let bundle = certificates.bundle.path
            variables += [
                ("SSL_CERT_FILE", bundle), ("REQUESTS_CA_BUNDLE", bundle), ("CURL_CA_BUNDLE", bundle),
                ("GIT_SSL_CAINFO", bundle), ("NODE_EXTRA_CA_CERTS", certificates.root.path),
            ]
        }
        return variables.map { (name: $0.0, value: $0.1) }
    }

    /// The shells the text is for.
    public enum Shell: Hashable, Sendable {
        /// bash, zsh and other shells that take `export`.
        case posix
        case fish

        /// The shell `SHELL` names, such as `/usr/bin/fish`.
        public init(shell: String?) {
            self = shell.map { URL(filePath: $0).lastPathComponent } == "fish" ? .fish : .posix
        }
    }

    /// The text to paste into `shell`: a line or two of `export` for bash and zsh, or `set -gx`
    /// for fish.
    public func text(for shell: Shell) -> String {
        let variables = variables
        switch shell {
        case .posix:
            // A few variables a line, as the plan shows them.
            let lines = stride(from: 0, to: variables.count, by: 2).map { start in
                "export "
                    + variables[start..<min(start + 2, variables.count)].map {
                        "\($0.name)=\(Self.posixQuoted($0.value))"
                    }.joined(separator: " ")
            }
            return lines.joined(separator: "\n") + "\n"
        case .fish:
            return variables.map { "set -gx \($0.name) \(Self.fishQuoted($0.value))\n" }.joined()
        }
    }

    /// Removes the proxy variables from Reqly's own environment, as it starts, before any other
    /// thread runs: a Reqly started from a terminal set up for it would otherwise send its own
    /// requests, such as update checks, through itself.
    public static func removeProxyVariablesFromThisProcess() {
        for name in proxyVariables {
            unsetenv(name)
        }
    }

    /// `environment` without the proxy variables.
    public static func withoutProxyVariables(_ environment: [String: String]) -> [String: String] {
        environment.filter { !proxyVariables.contains($0.key) }
    }

    // MARK: - Quoting

    /// Characters that need no quotes in either shell.
    private static func isPlain(_ text: String) -> Bool {
        !text.isEmpty
            && text.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || "@%+=:,./_-".unicodeScalars.contains($0)
            }
    }

    /// `text` for a POSIX shell: as it is when it's plain, otherwise in single quotes, with each
    /// single quote closed, escaped and opened again.
    static func posixQuoted(_ text: String) -> String {
        isPlain(text) ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `text` for fish: as it is when it's plain, otherwise in single quotes, inside which fish
    /// takes a backslash before a single quote or another backslash.
    static func fishQuoted(_ text: String) -> String {
        guard !isPlain(text) else { return text }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}
