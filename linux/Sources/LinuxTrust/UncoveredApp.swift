import Foundation

/// A kind of app that none of the places reaches, since it keeps a list of certificates of its
/// own, with what makes it trust Reqly's certificate, as Settings › HTTPS lists them under Not
/// Covered. A terminal set up for Reqly covers Node and Python by itself.
public struct UncoveredApp: Sendable, Equatable {
    public var name: String
    /// Why the places don't reach it, and what the fix does.
    public var detail: String
    /// The fix to copy: a command, lines for a file, or the certificate's path.
    public var fix: String

    public init(name: String, detail: String, fix: String) {
        self.name = name
        self.detail = detail
        self.fix = fix
    }

    /// Each, with its fix for the certificate in `pemFile`, `Reqly CA.pem`, and the computer's list
    /// with it added in `bundleFile`, as LinuxRootStore keeps them.
    public static func all(pemFile: URL, bundleFile: URL) -> [UncoveredApp] {
        let pem = ComputerList.quoted(pemFile.path)
        return [
            UncoveredApp(
                name: "Node from nodejs.org or nvm",
                detail: "It reads only its own list. This adds Reqly's certificate to it, for what you start "
                    + "from the same shell:",
                fix: "export NODE_EXTRA_CA_CERTS=\(pem)"),
            UncoveredApp(
                name: "Python in a virtual environment",
                detail: "Requests and pip there read certifi's list, not this computer's. This points them at "
                    + "this computer's list with Reqly's certificate added:",
                fix: "export REQUESTS_CA_BUNDLE=\(ComputerList.quoted(bundleFile.path))"),
            UncoveredApp(
                name: "Java you installed yourself",
                detail: "It keeps a keystore of its own. This adds Reqly's certificate to it, with that Java's "
                    + "keytool:",
                fix: "keytool -importcert -cacerts -storepass changeit -noprompt -alias reqly-ca -file \(pem)"),
            UncoveredApp(
                name: "Docker containers",
                detail: "Each image has its own list. For an image based on Debian or Ubuntu, copy Reqly CA.pem "
                    + "from \(pemFile.deletingLastPathComponent().path) beside its Dockerfile, then add these "
                    + "lines to it:",
                fix: "COPY [\"Reqly CA.pem\", \"/usr/local/share/ca-certificates/reqly-ca.crt\"]\n"
                    + "RUN update-ca-certificates"),
            UncoveredApp(
                name: "Snap and Flatpak browsers Reqly doesn't know about",
                detail: "They keep certificates in folders of their own. Import Reqly's certificate in the "
                    + "browser's own certificate settings, from this file:",
                fix: pemFile.path),
        ]
    }
}
