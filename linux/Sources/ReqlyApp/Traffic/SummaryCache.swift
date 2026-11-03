import Foundation
import ReqlyModel

/// The rows' contents, as the session last gave them, for the rows GTK has bound to cells, which
/// are the ones on screen and a few around them. A row's contents are asked for as it's bound,
/// those of every row a frame binds in one call, rather than for every row that arrives, so a
/// burst, or every row of a session again, asks for no more than the window shows.
struct SummaryCache {
    /// A row's contents, and what its cells say.
    struct Entry: Equatable {
        var summary: ExchangeSummary
        var text: RowText
    }

    /// How many rows it keeps the contents of, past which it keeps only the bound ones.
    static let kept = 4096

    private var entries: [ExchangeID: Entry] = [:]
    /// Rows that were bound with no contents yet, in the order they were, until they're asked for.
    private var wanted: [ExchangeID] = []
    private var isWanted: Set<ExchangeID> = []
    private let locale: Locale
    private let timeZone: TimeZone

    init(locale: Locale = .current, timeZone: TimeZone = .current) {
        self.locale = locale
        self.timeZone = timeZone
    }

    subscript(id: ExchangeID) -> Entry? { entries[id] }

    var count: Int { entries.count }

    /// Whether rows wait to be asked for.
    var hasWanted: Bool { !wanted.isEmpty }

    /// A row was bound: its contents, or `nil`, after which they're wanted.
    mutating func bound(_ id: ExchangeID) -> Entry? {
        if let entry = entries[id] {
            return entry
        }
        want(id)
        return nil
    }

    /// Rows whose contents changed: the bound ones are asked for again, and the others forgotten,
    /// to be asked for once they're bound.
    mutating func changed(_ ids: [ExchangeID], isBound: (ExchangeID) -> Bool) {
        for id in ids {
            if isBound(id) {
                want(id)
            } else {
                entries[id] = nil
            }
        }
    }

    /// Rows that came in, which may have come back: what changed while a filter hid them isn't
    /// said, so their contents are forgotten.
    mutating func inserted(_ ids: [ExchangeID]) {
        for id in ids {
            entries[id] = nil
        }
    }

    /// Every row came again, so any of them may show something new.
    mutating func forgetAll() {
        entries.removeAll(keepingCapacity: true)
    }

    /// The rows to ask for now, each once.
    mutating func takeWanted() -> [ExchangeID] {
        defer {
            wanted = []
            isWanted = []
        }
        return wanted
    }

    /// The contents the session gave, kept for the rows still bound, which are given back to
    /// fill in. Past ``kept`` rows, it keeps only the bound ones.
    mutating func received(_ summaries: [ExchangeSummary], isBound: (ExchangeID) -> Bool) -> [Entry] {
        var filled: [Entry] = []
        for summary in summaries where isBound(summary.id) {
            let entry = Entry(summary: summary, text: RowText(summary, locale: locale, timeZone: timeZone))
            entries[summary.id] = entry
            filled.append(entry)
        }
        if entries.count > Self.kept {
            entries = entries.filter { isBound($0.key) }
        }
        return filled
    }

    /// Changes a row's contents at once, as a pin does before the session says so, and gives the
    /// new entry, or `nil` when there's none to change.
    mutating func update(_ id: ExchangeID, _ change: (inout ExchangeSummary) -> Void) -> Entry? {
        guard var summary = entries[id]?.summary else { return nil }
        change(&summary)
        let entry = Entry(summary: summary, text: RowText(summary, locale: locale, timeZone: timeZone))
        entries[id] = entry
        return entry
    }

    private mutating func want(_ id: ExchangeID) {
        if isWanted.insert(id).inserted {
            wanted.append(id)
        }
    }
}
