import CoreInterface
import ReqlyModel

/// The list's changes on their way into its view, a piece at a time. GTK lays out each change
/// it's told of, so a burst of thousands of rows, or every row of a session again as a search
/// ends, goes in as many pieces as fit in a few milliseconds, then the window draws, and the list
/// goes on: the splices ``RowMirror`` gives, in order, each cut into pieces of at most
/// ``pieceRows`` rows. A splice's first piece takes out all the rows it takes out, as removing is
/// quick. A change that puts in every row again takes the place of the pieces still waiting, as
/// a search does each time you type.
struct RowFeed {
    /// A piece of a splice, as `gtk_string_list_splice` takes it.
    struct Piece: Equatable {
        var position: Int
        var removing: Int
        var inserting: ArraySlice<ExchangeID>
    }

    /// The most rows a piece puts in.
    static let pieceRows = 2048

    /// The splices waiting, each with whether its change puts in every row again.
    private var waiting: [(splice: RowMirror.Splice, isWhole: Bool)] = []
    /// The first splice not all in yet.
    private var head = 0
    /// How many of its rows are in.
    private var done = 0

    /// Whether every piece is in.
    var isEmpty: Bool { head == waiting.count }

    /// Whether the piece to come is of a change that puts in every row again, which the list
    /// doesn't follow until it's all in.
    var isResetting: Bool { head < waiting.count && waiting[head].isWhole }

    /// Adds a change's splices after those waiting, or for one that puts in every row again, in
    /// their place: its first splice then takes out the `shown` rows the view has.
    mutating func append(_ change: RowMirror.Change, shown: Int) {
        var splices = change.splices
        if change.isWhole, !isEmpty, !splices.isEmpty {
            waiting.removeAll(keepingCapacity: true)
            head = 0
            done = 0
            splices[0].removing = shown
        }
        waiting += splices.map { ($0, change.isWhole) }
    }

    /// The next piece, or `nil` once they're all in.
    mutating func next() -> Piece? {
        guard head < waiting.count else { return nil }
        let splice = waiting[head].splice
        let end = min(splice.inserting.count, done + Self.pieceRows)
        let piece = Piece(
            position: splice.position + done, removing: done == 0 ? splice.removing : 0,
            inserting: splice.inserting[done..<end])
        done = end
        if done == splice.inserting.count {
            head += 1
            done = 0
            if head == waiting.count {
                waiting.removeAll(keepingCapacity: true)
                head = 0
            }
        }
        return piece
    }
}

/// Whether the list follows new traffic, as the Mac's does: decided before each change, from
/// whether the list shows its last row, or nearly, or is still following rows it hasn't shown
/// yet, which push its end out of view. It follows rows that come in, rather than a change in
/// their count, so it keeps following past the store's limit, where as many old rows go as new
/// ones come. The newest row is shown at most every 100 ms, and not while every row is going in
/// again, as after a search ends, but once they're in.
struct Following {
    /// What the list does about its newest row after a change.
    enum Reveal: Equatable {
        case none
        case now
        /// Once this many milliseconds have gone, unless more changes show it before.
        case after(milliseconds: Int)
    }

    /// The least time between two reveals, in microseconds.
    static let revealEvery = 100_000

    private(set) var isFollowing = false
    /// Whether rows came in since the newest row last showed.
    private(set) var hasUnrevealed = false
    /// When the newest row last showed, in monotonic microseconds.
    private var revealedAt: Int?

    /// Before a change: whether the list follows it. `showsEnd` is whether its last row shows now.
    @discardableResult
    mutating func begin(showsEnd: Bool) -> Bool {
        isFollowing = (isFollowing && hasUnrevealed) || showsEnd
        return isFollowing
    }

    /// After a change that put `inserted` rows in: whether to show the newest row, at `now`.
    /// `isDone` is whether every piece is in, and `isResetting` whether every row is still
    /// going in again.
    mutating func end(inserted: Int, isDone: Bool, isResetting: Bool, now: Int) -> Reveal {
        hasUnrevealed = isFollowing && (hasUnrevealed || inserted > 0)
        return reveal(isDone: isDone, isResetting: isResetting, now: now)
    }

    /// Stops following at once, as you scroll up: a newest row still to show stays where it is.
    /// Back at its end, the list follows the next change.
    mutating func stop() {
        isFollowing = false
        hasUnrevealed = false
    }

    /// Whether to show the newest row now, as after waiting for the time between reveals to pass.
    mutating func reveal(isDone: Bool, isResetting: Bool, now: Int) -> Reveal {
        guard hasUnrevealed, !isResetting else { return .none }
        let since = revealedAt.map { now - $0 } ?? Int.max
        if since >= Self.revealEvery {
            hasUnrevealed = false
            revealedAt = now
            return .now
        }
        // Changes still to come show it, once the time's up.
        return isDone ? .after(milliseconds: (Self.revealEvery - since + 999) / 1000) : .none
    }
}
