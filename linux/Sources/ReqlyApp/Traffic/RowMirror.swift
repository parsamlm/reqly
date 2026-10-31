import CoreInterface
import ReqlyModel

/// The list's rows, kept in step with the session's: each `rows` event's steps applied in order,
/// as the Windows app applies them, turned into splices for the list's GtkStringList. An event
/// must follow the one before: when one is missing, or a step names a row the list doesn't have,
/// the mirror waits for every row from ``SessionHost/rowIDs()``, keeping the events that come
/// meanwhile, and goes on from there.
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
        var inserted: [ExchangeID] {
            splices.flatMap(\.inserting)
        }
    }

    /// The version of the rows the latest event had.
    private(set) var version = 0
    private(set) var ids: [ExchangeID] = []
    /// The exchanges the rows show, for finding one at once.
    private(set) var members: Set<ExchangeID> = []
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
    /// list's rows these. The rows that stay count as changed, since what changed in them came in
    /// the events every row stands in for.
    mutating func reset(version: Int, ids all: [ExchangeID]) -> Change {
        var change = Change(
            splices: [Splice(position: 0, removing: ids.count, inserting: all)], changed: all.filter(members.contains))
        self.version = version
        ids = all
        members = Set(all)
        isWaitingForRows = false
        let waiting = held
        held = []
        for event in waiting {
            if let more = receive(version: event.version, steps: event.steps) {
                change.splices += more.splices
                change.changed += more.changed
            }
        }
        return change
    }

    /// The rows after `steps`, and the splices that make them, or `nil` when a step doesn't fit
    /// the rows, which then stay as they were.
    private mutating func apply(_ steps: [RowStep]) -> Change? {
        var rows = ids
        var shown = members
        var change = Change()
        for step in steps {
            switch step {
            case .removed(let places):
                // The last first, so the places before stay where they were, a run of neighbors
                // at a time.
                var places = places.sorted(by: >)[...]
                while let last = places.popFirst() {
                    guard rows.indices.contains(last) else { return nil }
                    var first = last
                    while let next = places.first, next == first - 1 {
                        first = next
                        places = places.dropFirst()
                    }
                    shown.subtract(rows[first...last])
                    rows.removeSubrange(first...last)
                    change.splices.append(Splice(position: first, removing: last - first + 1, inserting: []))
                }
            case .inserted(let new):
                // Each at its place after, in order, a run of neighbors at a time.
                var start = new.startIndex
                while start < new.endIndex {
                    guard (0...rows.count).contains(new[start].row) else { return nil }
                    var end = start + 1
                    while end < new.endIndex, new[end].row == new[end - 1].row + 1 {
                        end += 1
                    }
                    let run = new[start..<end].map(\.id)
                    rows.insert(contentsOf: run, at: new[start].row)
                    shown.formUnion(run)
                    change.splices.append(Splice(position: new[start].row, removing: 0, inserting: run))
                    start = end
                }
            case .changed(let changed):
                change.changed += changed
            case .reset(let all):
                // Every row comes in place of steps, which may have changed rows that stay.
                change.changed += all.filter(shown.contains)
                change.splices.append(Splice(position: 0, removing: rows.count, inserting: all))
                rows = all
                shown = Set(all)
            }
        }
        ids = rows
        members = shown
        return change
    }
}
