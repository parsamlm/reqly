import Foundation

/// The computer's list of certificates, which OpenSSL and GnuTLS apps such as curl and GNOME's
/// read. The helper, reqly-trust, adds Reqly's root to it as root, one file for each account.
/// Changing it asks for an administrator's password, and the change applies to every account on
/// the computer. Anyone can read the list, so checking it needs no password.
public enum ComputerList {
    /// The list update-ca-certificates builds, which most apps read.
    public static let bundle = "/etc/ssl/certs/ca-certificates.crt"

    /// Where the helper puts your account's root, before update-ca-certificates adds it.
    public static func certificateFile(uid: UInt32) -> String {
        "/usr/local/share/ca-certificates/reqly/reqly-ca-\(uid).crt"
    }

    /// The link that update-ca-certificates makes to it, so its being there means the computer
    /// trusts it.
    public static func linkedFile(uid: UInt32) -> String {
        "/etc/ssl/certs/reqly-ca-\(uid).pem"
    }

    /// Whether the list at `bundle` has the certificate `der`, by its bytes.
    public static func contains(_ der: [UInt8], bundle: String = bundle) -> Bool {
        guard let text = try? String(contentsOfFile: bundle, encoding: .utf8) else { return false }
        return PEM.certificates(in: text).contains(der)
    }

    /// The commands that add the certificate in `pemFile` by hand, for when there's no password
    /// dialog, one to a line.
    public static func commandsToAdd(pemFile: URL, uid: UInt32) -> String {
        let file = certificateFile(uid: uid)
        return """
            sudo mkdir -p \((file as NSString).deletingLastPathComponent)
            sudo tee \(file) < \(quoted(pemFile.path)) > /dev/null
            sudo update-ca-certificates
            """
    }

    /// The commands that remove your account's certificate by hand, one to a line.
    public static func commandsToRemove(uid: UInt32) -> String {
        let file = certificateFile(uid: uid)
        return """
            sudo rm -f \(file)
            sudo rmdir --ignore-fail-on-non-empty \((file as NSString).deletingLastPathComponent)
            sudo update-ca-certificates --fresh
            """
    }

    /// `text` as one word for a POSIX shell.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs the helper, reqly-trust, as root through pkexec, which asks for an administrator's
/// password in your desktop's own dialog. The polkit action net.reqly.trust names the installed
/// helper, so its dialog says what Reqly is about to do; a helper elsewhere, for development runs,
/// gets pkexec's general question instead.
public struct TrustHelper: Sendable {
    /// Where the package installs the helper.
    public static let installedPath = "/usr/libexec/reqly/reqly-trust"
    /// Where Debian and Ubuntu install pkexec. Reqly never looks for it through `PATH`, which
    /// may name a folder of yours first, where any program could leave one that asks for the
    /// administrator's password in its place.
    public static let pkexecPath = "/usr/bin/pkexec"

    /// The helper's path.
    public var path: String
    /// pkexec's path, which only tests change.
    public var pkexec: String
    /// The environment pkexec runs with.
    public var environment: [String: String]
    /// Your account, which the commands to run by hand name.
    public var uid: UInt32
    /// Whether pkexec may ask for the password in the terminal Reqly runs in, when there's no
    /// password dialog, as `reqly --remove-certificate` lets it. Reqly's window never does: you
    /// may never see a question in the terminal it was started from.
    public var asksInTerminal = false

    public init(
        path: String = installedPath, pkexec: String = pkexecPath,
        environment: [String: String] = ProcessInfo.processInfo.environment, uid: UInt32 = getuid()
    ) {
        self.path = path
        self.pkexec = pkexec
        self.environment = environment
        self.uid = uid
    }

    /// Why the helper is missing, or pkexec, or `nil` when both are there.
    public var unavailableReason: String? {
        if access(pkexec, X_OK) != 0 {
            return "Changing this computer's list needs pkexec, from the pkexec package."
        }
        if access(path, X_OK) != 0 {
            return "Reqly's helper, \(path), isn't installed."
        }
        return nil
    }

    /// Adds the certificate in `pem`, which the helper reads on standard input, so root never
    /// reads a file in your home folder. `pemFile` holds the same, for the commands to run by
    /// hand when there's no password dialog. It waits as long as the dialog is open.
    public func add(pem: String, pemFile: URL, cancellation: Cancellation? = nil) throws(TrustProblem) {
        try run(
            "add", input: Data(pem.utf8), byHand: ComputerList.commandsToAdd(pemFile: pemFile, uid: uid),
            cancellation: cancellation)
    }

    /// Removes your account's certificate. It waits as long as the dialog is open.
    public func remove(cancellation: Cancellation? = nil) throws(TrustProblem) {
        try run("remove", input: Data(), byHand: ComputerList.commandsToRemove(uid: uid), cancellation: cancellation)
    }

    private func run(_ action: String, input: Data, byHand: String, cancellation: Cancellation?) throws(TrustProblem) {
        if let reason = unavailableReason { throw .unavailable(reason) }
        let ended: ToolRun.Ended
        do {
            // In a session of its own, so with no polkit agent it can't fall back to asking in the
            // terminal Reqly was started from, where you may never see it, unless it may ask there.
            ended = try ToolRun(
                path: pkexec, arguments: [path, action], environment: ToolRun.withoutProxy(environment), input: input,
                cancellation: cancellation, newSession: !asksInTerminal
            ).run()
        } catch .cancelled {
            throw .cancelled
        } catch {
            throw .failed("Reqly couldn't start pkexec.")
        }
        switch ended.status {
        case 0:
            return
        // pkexec's own: you closed its dialog.
        case 126:
            throw .cancelled
        // pkexec's own: not allowed, or no way to ask. With no polkit agent and no terminal, it
        // can't ask for a password at all.
        case 127 where ended.errorText.contains("textual authentication agent"):
            throw .noPasswordDialog(commands: byHand)
        case 127:
            throw .notAllowed
        default:
            let said = ended.errorText.isEmpty ? "It ended with status \(ended.status)." : ended.errorText
            throw .failed("Reqly's helper couldn't change this computer's list. \(said)")
        }
    }
}

/// Why Reqly couldn't trust its certificate in a place, or remove it from one.
public enum TrustProblem: Error, Sendable, Equatable, LocalizedError {
    /// You closed the password dialog.
    case cancelled
    /// There's no password dialog, as on some tiling window managers. `commands` do it by hand,
    /// in a terminal.
    case noPasswordDialog(commands: String)
    /// Your account isn't allowed to.
    case notAllowed
    /// What it needs is missing, such as certutil or pkexec.
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "The password dialog was closed."
        case .noPasswordDialog(let commands):
            "No password dialog is available, so Reqly can't ask for an administrator's password. "
                + "To do it yourself, run these in a terminal:\n\(commands)"
        case .notAllowed:
            "Your account isn't allowed to change this computer's list of certificates. Ask an administrator."
        case .unavailable(let reason), .failed(let reason):
            reason
        }
    }
}
