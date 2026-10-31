import CoreInterface
import Foundation
import LinuxSystem

/// How this run of Reqly is set up, from its command line: `--name value`, with the Windows app's
/// names where Windows has them (windows/Reqly/AppOptions.cs). Test runs point everything at files
/// of their own and use stand-ins for your settings, as the Mac's and Windows' test launches do:
///
///     reqly --proxy-settings-stand-in <file> --proxy-restore-file <file> --root-stand-in <file>
///         --secrets-stand-in <file> --settings-file <file> --sessions-folder <dir> --port 9191
///
/// A run given a stand-in, its own settings file or `--smoke` is a test run: it runs beside a
/// Reqly that's open, and leaves your desktop's proxy alone unless it has a stand-in for it.
public struct Options: Sendable, Equatable {
    /// What the run does.
    public enum Command: Sendable, Equatable {
        /// Opens Reqly's window, or brings back the one that's open.
        case open
        /// `--remove-certificate`: removes Reqly's certificate for your account, with no window.
        case removeCertificate
        case help
        case version
    }

    /// A command line Reqly can't follow, with what to fix.
    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public var description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    public var command = Command.open
    /// The port, in place of the one in your settings. 0 picks a free one.
    public var port: Int?
    /// Whether capturing starts at once, in place of the choice in your settings.
    public var startsCapturing: Bool?
    /// A JSON file that stands in for your desktop's proxy settings, so the switch runs without
    /// changing yours.
    public var proxySettingsStandIn: String?
    public var proxyRestoreFile: String?
    public var settingsFile: String?
    public var rulesFile: String?
    public var connectionsFile: String?
    public var protobufFile: String?
    public var devicesFile: String?
    public var sessionsFolder: String?
    public var crashReportsFolder: String?
    /// Where Reqly's standard error goes, such as GLib's warnings, in place of the terminal's.
    public var logFile: String?
    /// A plain file for the secrets, so the run needs nothing of your keyring.
    public var secretsStandIn: String?
    /// Where Reqly's certificate goes, and its key when there's no keyring.
    public var rootFile: String?
    /// A plain file for a certificate that counts as trusted, so the run decrypts while nothing on
    /// the computer trusts it: not your browsers, Firefox or the computer's list.
    public var rootStandIn: String?
    /// The root helper to trust the certificate in the computer's list with, such as a development
    /// build's copy, in place of the installed one.
    public var trustHelper: String?
    /// Whether devices on the network may connect, in place of the choice in your settings.
    public var allowsNetworkDevices: Bool?
    /// Whether Reqly checks for a newer version, in place of the choice in your settings.
    public var checksForUpdates: Bool?
    /// Whether the welcome guide counts as seen, so it stays closed.
    public var hasSeenWelcome: Bool?
    /// Light or dark, whatever your desktop uses, for pictures of both.
    public var theme: Theme?
    /// `--smoke <report>`: runs the self-check, writes what it found to the report, and quits.
    public var smokeReport: String?
    /// The self-check's parts to run, or all of them.
    public var smokeParts: [String]?
    /// An application ID of the run's own, in place of Reqly's, under which a test run is the
    /// only one, as a real run is under Reqly's: the self-check starts two with the same ID.
    public var appID: String?
    /// `--sets-system-proxy`, when it's given.
    private var setsSystemProxyOption: Bool?

    public enum Theme: String, Sendable {
        case light, dark
    }

    public init(_ arguments: [String]) throws(UsageError) {
        var rest = arguments[...]
        while let name = rest.popFirst() {
            func value() throws(UsageError) -> String {
                guard let value = rest.popFirst() else { throw UsageError("\(name) needs a value.") }
                return value
            }
            func yesOrNo() throws(UsageError) -> Bool {
                switch try value() {
                case "yes": return true
                case "no": return false
                case let other: throw UsageError("\(name) takes yes or no, not \(other).")
                }
            }
            switch name {
            case "--help", "-h": command = .help
            case "--version": command = .version
            case "--remove-certificate": command = .removeCertificate
            case "--port":
                let text = try value()
                guard let number = Int(text), (0...65535).contains(number) else {
                    throw UsageError("--port takes a number from 0 to 65535, not \(text).")
                }
                port = number
            case "--starts-capturing": startsCapturing = try yesOrNo()
            case "--sets-system-proxy": setsSystemProxyOption = try yesOrNo()
            case "--proxy-settings-stand-in": proxySettingsStandIn = try value()
            case "--proxy-restore-file": proxyRestoreFile = try value()
            case "--settings-file": settingsFile = try value()
            case "--rules-file": rulesFile = try value()
            case "--connections-file": connectionsFile = try value()
            case "--protobuf-file": protobufFile = try value()
            case "--devices-file": devicesFile = try value()
            case "--sessions-folder": sessionsFolder = try value()
            case "--crash-reports-folder": crashReportsFolder = try value()
            case "--log-file": logFile = try value()
            case "--secrets-stand-in": secretsStandIn = try value()
            case "--root-file": rootFile = try value()
            case "--root-stand-in": rootStandIn = try value()
            case "--trust-helper": trustHelper = try value()
            case "--allows-network-devices": allowsNetworkDevices = try yesOrNo()
            case "--checks-for-updates": checksForUpdates = try yesOrNo()
            case "--has-seen-welcome": hasSeenWelcome = try yesOrNo()
            case "--theme":
                let text = try value()
                guard let chosen = Theme(rawValue: text) else {
                    throw UsageError("--theme takes light or dark, not \(text).")
                }
                theme = chosen
            case "--smoke": smokeReport = try value()
            case "--smoke-parts":
                let parts = try value().split(separator: ",").map(String.init)
                guard !parts.isEmpty else { throw UsageError("--smoke-parts needs the names of parts.") }
                smokeParts = parts
            case "--app-id": appID = try value()
            default:
                throw UsageError("Reqly has no option \(name). See reqly --help.")
            }
        }
    }

    /// Whether this is a test run: one given a stand-in, its own settings file, its own
    /// application ID or `--smoke`.
    public var isTestRun: Bool {
        proxySettingsStandIn != nil || rootStandIn != nil || secretsStandIn != nil || settingsFile != nil
            || smokeReport != nil || appID != nil
    }

    /// Whether capturing points your desktop's proxy at Reqly, or the stand-in's: as
    /// `--sets-system-proxy` says, or else yes, but for a test run only with a stand-in, so a test
    /// never changes your own settings unless it's told to.
    public var setsSystemProxy: Bool {
        setsSystemProxyOption ?? (!isTestRun || proxySettingsStandIn != nil)
    }

    /// Linux's parts for the session, with `--trust-helper`'s root helper if there's one.
    public var systemParts: SystemParts {
        trustHelper.map { SystemParts.linux(trustHelper: $0) } ?? .linux
    }

    /// What `--help` says.
    public static let help = """
        Usage: reqly [options]

        Reqly shows what your apps send and receive.

          --remove-certificate  Remove Reqly's certificate from your browsers, this computer's
                                list and your keyring, then quit, as before uninstalling Reqly.
                                Removing it from the computer's list asks for a password.
          --help                Show this help, then quit.
          --version             Show Reqly's version, then quit.

        For test runs, each in place of your settings or of the file Reqly keeps:
          --port <number>                   --starts-capturing yes|no
          --sets-system-proxy yes|no        --proxy-settings-stand-in <file>
          --proxy-restore-file <file>       --settings-file <file>
          --rules-file <file>               --connections-file <file>
          --protobuf-file <file>            --devices-file <file>
          --sessions-folder <folder>        --crash-reports-folder <folder>
          --log-file <file>                 --secrets-stand-in <file>
          --root-file <file>                --root-stand-in <file>
          --trust-helper <program>          --allows-network-devices yes|no
          --checks-for-updates yes|no       --has-seen-welcome yes|no
          --theme light|dark                --smoke <report>
          --smoke-parts <part>,<part>...    --app-id <id>

        A run with a stand-in, its own settings file, --app-id or --smoke is a test run: it runs
        beside the Reqly that's open, as the only run under its --app-id if it has one, and
        changes your desktop's own proxy only when given --sets-system-proxy yes and no
        --proxy-settings-stand-in.

        """
}
