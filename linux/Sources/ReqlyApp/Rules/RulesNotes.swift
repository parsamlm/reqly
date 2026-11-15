import CoreInterface
import Foundation
import ReqlyModel

extension AppModel {
    /// The rules' status notes, while kinds are on: Linux has one Rules button where the Mac and
    /// Windows show Breakpoints and Slow Network, so the status line says which are on too.
    var rulesNotes: [StatusNote] {
        guard let set = rules?.set else { return [] }
        return RulesNotes.notes(kindsOn: set.kindsOn, network: set.network)
    }
}

/// The words of the rules' status notes: " · Breakpoints on", " · Breakpoints and Map Local on",
/// for the kinds that act on the requests they match, and " · Slow Network: 3G", with the profile
/// it slows traffic with, each with its sentence.
enum RulesNotes {
    static func notes(kindsOn: Set<RuleKind>, network: NetworkConditions) -> [StatusNote] {
        var notes: [StatusNote] = []
        let kinds = RuleKind.allCases.filter { $0 != .slowNetwork && kindsOn.contains($0) }.map(\.title)
        if let last = kinds.last {
            let list = kinds.count == 1 ? last : kinds.dropLast().joined(separator: ", ") + " and " + last
            // Breakpoints and Scripts are many; Map Local, Rewrite and the rest one.
            let isMany = kinds.count > 1 || last.hasSuffix("s")
            let sentence =
                "\(list) \(isMany ? "are" : "is") on, so \(isMany ? "their" : "its") rules act on the requests they match."
            notes.append(StatusNote(text: "\(list) on", sentence: sentence))
        }
        if kindsOn.contains(.slowNetwork) {
            let profile = network.profile.name
            let hosts = network.hosts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let traffic =
                switch hosts.count {
                case 0: "all traffic"
                case 1: "traffic to \(hosts[0])"
                default: "traffic to \(hosts.count) hosts"
                }
            notes.append(
                StatusNote(
                    text: "Slow Network: \(profile)",
                    sentence: "Slow Network slows \(traffic), with the \(profile) profile."))
        }
        return notes
    }
}
