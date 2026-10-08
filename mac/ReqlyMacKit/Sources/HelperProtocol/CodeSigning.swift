import Foundation
import Security

/// How the running program is signed. The app and the helper only talk to each other when both
/// are signed by the same team.
public struct CodeSigningInfo: Sendable, Equatable {
    public var identifier: String
    /// `nil` for builds signed to run locally, which have no team.
    public var teamIdentifier: String?

    public init(identifier: String, teamIdentifier: String?) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
    }

    /// The signature of the running program, or `nil` if it isn't signed.
    public static func current() -> CodeSigningInfo? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
            let information = information as? [String: Any],
            let identifier = information[kSecCodeInfoIdentifier as String] as? String
        else { return nil }
        return CodeSigningInfo(
            identifier: identifier, teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    /// A code signing requirement that only a program with `identifier`, signed by `team`
    /// through Apple, can meet.
    public static func requirement(identifier: String, team: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
