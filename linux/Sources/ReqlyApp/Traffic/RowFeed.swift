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

    /// The least time between two reveals here: ``revealEvery``, unless the self-check holds the
    /// newest row back longer, so that it waits its turn for sure.
    var between = Self.revealEvery
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
        if since >= between {
            hasUnrevealed = false
            revealedAt = now
            return .now
        }
        // Changes still to come show it, once the time's up.
        return isDone ? .after(milliseconds: (between - since + 999) / 1000) : .none
    }
}

/// How the list goes to its very end, frame after frame, once it has asked GTK to scroll to its
/// newest row. GTK places a row it hasn't laid out yet by a guess: GTK 4.14 puts a new last row's
/// top on the bottom edge, as if it had no height, and later versions leave it just below. So
/// in each frame, before GTK lays it out, the list moves to its end, until a frame's layout has
/// left it there with its end where it was, and every change and the rows' contents in. On a
/// slow computer, GTK may lay out the rows the list last asked for frames after the list was
/// first at its end, so it gives up after a time rather than a number of frames. Rows that come
/// after the list asked wait for their own turn to show, as the list shows its newest row at most
/// every 100 ms. It stops as you scroll up from where it left the list, as a touchscreen does: the
/// list stops it itself for the keys, the wheel and the scrollbar.
struct GoingToTheEnd {
    /// What the list does in a frame, before GTK lays the frame out.
    enum Step: Equatable {
        /// Nothing, this frame.
        case wait
        /// Its scroll position to its end, here.
        case move(to: Double)
        /// Nothing more: it's at its end with everything in, or you scrolled, or the time's up.
        case stop
    }

    /// The longest it goes on after the list last asked for its newest row, in microseconds.
    static let timeLimit = 2_000_000

    /// Whether it goes on, frame after frame.
    private(set) var isGoing = false
    /// Counts each time it starts or stops, so a frame callback of an earlier time can stop.
    private(set) var round = 0
    /// When the list last asked for its newest row, in monotonic microseconds.
    private var askedAt = 0
    /// Whether the list asked for its newest row since the last frame, which GTK goes to in the
    /// next frame's layout, not before: a frame at the end until then isn't at its end for good,
    /// nor is the list moving there you scrolling.
    private var hasAsked = false
    /// Where the last frame left the list, from which scrolling up is yours.
    private var leftAt: Double?
    /// The end, as the last frame found the list there with everything in.
    private var steadyEnd: Double?

    /// The list asked GTK to scroll to its newest row, at `now`. Whether it starts going, when
    /// the list starts a frame callback.
    mutating func ask(now: Int) -> Bool {
        askedAt = now
        hasAsked = true
        guard !isGoing else { return false }
        isGoing = true
        round += 1
        return true
    }

    /// Stops at once, as you scroll up.
    mutating func stop() {
        isGoing = false
        round += 1
    }

    /// A frame, before its layout: the list's scroll position and its end, whether it still
    /// follows new traffic, whether rows came in since it last asked, and whether every change and
    /// the rows' contents are in, at `now`.
    mutating func frame(
        value: Double, end: Double, isFollowing: Bool, hasNewRows: Bool, isSettled: Bool, now: Int
    ) -> Step {
        guard isGoing else { return .stop }
        guard !hasAsked else {
            hasAsked = false
            leftAt = nil
            steadyEnd = nil
            return .wait
        }
        let isScrolled = leftAt.map { value < $0 - 0.5 } ?? false
        guard isFollowing, !isScrolled, now - askedAt < Self.timeLimit else {
            stop()
            return .stop
        }
        // They push the end out, and show once the list asks again.
        guard !hasNewRows else {
            steadyEnd = nil
            return .wait
        }
        guard value >= end - 0.5 else {
            leftAt = end
            steadyEnd = nil
            return .move(to: end)
        }
        leftAt = value
        if isSettled, let steadyEnd, abs(steadyEnd - end) < 0.5 {
            stop()
            return .stop
        }
        steadyEnd = isSettled ? end : nil
        return .wait
    }
}
