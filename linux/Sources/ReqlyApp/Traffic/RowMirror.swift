import CoreInterface
import ReqlyModel

/// The list's rows, kept in step with the session's: each `rows` event's steps applied in order,
/// as the Windows app applies them, turned into splices for the list's GtkStringList. An event
/// must follow the one before: when one is missing, or a step names a row the list doesn't have,
/// the mirror waits for every row from ``SessionHost/rowIDs()``, keeping the events that come
/// meanwhile, and goes on from there. It keeps only the rows' exchanges, in order, so an event
/// past the store's limit, with 100,000 rows, costs little more than its own steps.
///
/// An event whose steps would make more than ``mostSplices`` splices, as a search or a filter
/// leaving rows here and there, becomes one splice that puts in every row again: GTK takes each
/// splice near the end of a long list in milliseconds, so thousands of them took minutes.
struct RowMirror {
    /// A change to the rows, as `gtk_string_list_splice` takes it: at `position`, `removing` rows
    /// go and `inserting` take their place.
    struct Splice: Equatable {
        var position: Int
        var removing: Int
        var inserting: [ExchangeID]
    }

    /// What the list does about an event, or about every row.
    struct Change: Equatable {
        var splices: [Splice] = []
        /// Exchanges whose rows stay but show something new.
        var changed: [ExchangeID] = []
        /// The exchanges of the new rows, which the list asks the session for.
        var inserted: [ExchangeID] = []
        /// Whether its first splice puts in every row again, which the list doesn't follow until
        /// they're all in.
        var isWhole = false
        /// Whether every row came again, so any row may show something new.
        var isReset = false
    }

    /// The most splices an event makes; past them, it's one that puts in every row again.
    static let mostSplices = 64

    /// The version of the rows the latest event had.
    private(set) var version = 0
    private(set) var ids: [ExchangeID] = []
    /// Whether the mirror waits for every row, since an event was missing.
    private(set) var isWaitingForRows = false
    /// The events that came while it waits.
    private var held: [(version: Int, steps: [RowStep])] = []

    /// Takes in a `rows` event. Returns the change to make, or `nil` when there's none to make
    /// now: for an event the rows already have, or while the mirror waits for every row. After
    /// this, ask for every row when ``isWaitingForRows`` says so.
    mutating func receive(version next: Int, steps: [RowStep]) -> Change? {
        if isWaitingForRows {
            held.append((next, steps))
            return nil
        }
        guard next > version else { return nil }
        guard next == version + 1, let change = apply(steps) else {
            isWaitingForRows = true
            held.append((next, steps))
            return nil
        }
        version = next
        return change
    }

    /// Takes in every row, as of `version`, and the events held since: one change that makes the
    /// list's rows these. It's a reset, since what changed in the rows that stay came in the
    /// events every row stands in for.
    mutating func reset(version: Int, ids all: [ExchangeID]) -> Change {
        var change = Change(
            splices: [Splice(position: 0, removing: ids.count, inserting: all)], inserted: all, isWhole: true,
            isReset: true)
        self.version = version
        ids = all
        isWaitingForRows = false
        let waiting = held
        held = []
        for event in waiting {
            if let more = receive(version: event.version, steps: event.steps) {
                change.splices += more.splices
                change.changed += more.changed
                change.inserted += more.inserted
            }
        }
        return change
    }

    /// The rows after `steps`, and the splices that make them, or `nil` when a step doesn't fit
    /// the rows, which then stay as they were. Each step goes through the rows once, however
    /// many places it names.
    private mutating func apply(_ steps: [RowStep]) -> Change? {
        var rows = ids
        var change = Change()
        for step in steps {
            switch step {
            case .removed(let places):
                // A run of neighbors at a time, the last first, so the places before stay where
                // they were as the list splices them. The rows lose them all at once.
                var runs: [Range<Int>] = []
                var places = places.sorted(by: >)[...]
                while let last = places.popFirst() {
                    guard rows.indices.contains(last), runs.last.map({ last < $0.lowerBound }) ?? true else {
                        return nil
                    }
                    var first = last
                    while let next = places.first, next == first - 1 {
                        first = next
                        places = places.dropFirst()
                    }
                    runs.append(first..<last + 1)
                    change.splices.append(Splice(position: first, removing: last - first + 1, inserting: []))
                }
                rows.removeSubranges(RangeSet(runs))
            case .inserted(let new):
                // Each at its place after, in order, a run of neighbors at a time, between the
                // rows already there.
                var merged: [ExchangeID] = []
                merged.reserveCapacity(rows.count + new.count)
                var taken = 0
                var start = new.startIndex
                while start < new.endIndex {
                    let place = new[start].row
                    let before = place - merged.count
                    guard before >= 0, before <= rows.count - taken else { return nil }
                    merged += rows[taken..<taken + before]
                    taken += before
                    var end = start + 1
                    while end < new.endIndex, new[end].row == new[end - 1].row + 1 {
                        end += 1
                    }
                    let run = new[start..<end].map(\.id)
                    merged += run
                    change.splices.append(Splice(position: place, removing: 0, inserting: run))
                    change.inserted += run
                    start = end
                }
                merged += rows[taken...]
                rows = merged
            case .changed(let changed):
                change.changed += changed
            case .reset(let all):
                // Every row comes in place of steps, which may have changed rows that stay.
                change.isReset = true
                change.inserted += all
                rows = all
            }
        }
        if change.isReset || change.splices.count > Self.mostSplices {
            change.splices = [Splice(position: 0, removing: ids.count, inserting: rows)]
            change.isWhole = true
        }
        ids = rows
        return change
    }
}
