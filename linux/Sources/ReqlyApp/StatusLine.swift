/// A note the live window's status line adds after what capturing says, such as "Via
/// proxy.example.com:8080", "1 reverse proxy" or "Devices can connect", with the sentence that
/// says it in full, for the line's tooltip and for screen readers. Each feature gives its own: see
/// ``AppModel/statusNotes``.
struct StatusNote: Equatable, Sendable {
    /// What the line adds, after " · ".
    var text: String
    /// What it means, such as "Traffic goes through the upstream proxy at
    /// proxy.example.com:8080."
    var sentence: String
}

/// The status line's words: what capturing says, or a file window's name, then each note.
struct StatusLine: Equatable, Sendable {
    var status: String
    var notes: [StatusNote] = []

    var text: String { ([status] + notes.map(\.text)).joined(separator: " · ") }

    /// The line as a narrow window may cut it short, whole, then each note's sentence on a line of
    /// its own.
    var tooltip: String { ([text] + notes.map(\.sentence)).joined(separator: "\n") }

    /// What screen readers hear after the line's words: each note's sentence.
    var description: String { notes.map(\.sentence).joined(separator: " ") }
}

extension AppModel {
    /// The live window's status notes, in order: the upstream proxy's and the reverse proxies',
    /// the devices', as on the Mac, then the rule kinds that are on.
    var statusNotes: [StatusNote] { connectionsNotes + devicesNotes + rulesNotes }
}
