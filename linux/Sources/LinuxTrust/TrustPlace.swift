import Foundation

/// A place that decides whether apps trust Reqly's certificate, as Set Up HTTPS and Settings ›
/// HTTPS show it. Linux has no one store for your account, as the Mac and Windows do.
public struct TrustPlace: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The NSS databases that Chrome, Chromium, Edge, Brave and Electron apps read.
        case browsers
        /// Firefox's profiles, each with its own database. Firefox doesn't read the computer's list.
        case firefox
        /// The computer's list, which curl, GNOME's apps, Python, Node and most others read.
        case computer
    }

    public enum Status: Sendable, Equatable {
        /// It trusts the certificate: every database or profile it covers does.
        case trusted
        /// It doesn't yet, or not everywhere it covers.
        case notTrusted
        /// There's nothing to trust it in, such as a Firefox that hasn't been opened.
        case notFound
        /// Reqly can't change it, for this reason, such as a missing package.
        case unavailable(String)
    }

    public var kind: Kind
    public var status: Status
    /// The databases or Firefox profiles it covers, or the computer's list itself.
    public var locations: [URL]

    /// Its name, for the app to show.
    public var name: String {
        switch kind {
        case .browsers: "Chrome and other browsers built on it"
        case .firefox: "Firefox"
        case .computer: "Command-line tools and most other apps"
        }
    }

    /// Whether changing it asks for an administrator's password.
    public var needsPassword: Bool { kind == .computer }

    /// A sentence about it, for the app to show under its name.
    public var detail: String {
        if case .unavailable(let reason) = status { return reason }
        switch kind {
        case .browsers:
            return switch locations.count {
            case 0: "Open Chrome, or another browser built on it, once, then come back."
            case 1: "One certificate database. Restart your browsers afterwards."
            default: "\(locations.count) certificate databases. Restart your browsers afterwards."
            }
        case .firefox:
            return switch locations.count {
            case 0: "Open Firefox once, then come back."
            case 1: "One profile. Restart Firefox afterwards."
            default: "\(locations.count) profiles. Restart Firefox afterwards."
            }
        case .computer:
            return "This adds the certificate to this computer's list, for every account on it. "
                + "Linux asks for an administrator's password."
        }
    }

    public init(kind: Kind, status: Status, locations: [URL]) {
        self.kind = kind
        self.status = status
        self.locations = locations
    }
}
