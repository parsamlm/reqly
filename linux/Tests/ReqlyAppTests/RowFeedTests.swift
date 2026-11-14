import CoreInterface
import Foundation
import ReqlyModel
import Testing

@testable import ReqlyApp

/// The list's pieces, its following and the contents it asks for, without a window.
@Suite struct RowFeedTests {
    static func ids(_ range: ClosedRange<UInt64>) -> [ExchangeID] {
        range.map(ExchangeID.init(rawValue:))
    }

    /// The rows after every piece, as the view would have them.
    static func fed(_ start: [ExchangeID], _ feed: inout RowFeed) -> (rows: [ExchangeID], pieces: [RowFeed.Piece]) {
        var rows = start
        var pieces: [RowFeed.Piece] = []
        while let piece = feed.next() {
            rows.replaceSubrange(piece.position..<piece.position + piece.removing, with: piece.inserting)
            pieces.append(piece)
        }
        return (rows, pieces)
    }

    @Test func cutsABurstIntoPieces() {
        var feed = RowFeed()
        let none = feed.next()
        #expect(feed.isEmpty && none == nil)
        let burst = Self.ids(1...5_000)
        feed.append(RowMirror.Change(splices: [RowMirror.Splice(position: 0, removing: 0, inserting: burst)]), shown: 0)
        #expect(!feed.isEmpty && !feed.isResetting)
        let (rows, pieces) = Self.fed([], &feed)
        #expect(rows == burst)
        #expect(pieces.map(\.inserting.count) == [2048, 2048, 904])
        #expect(pieces.map(\.position) == [0, 2048, 4096])
        #expect(feed.isEmpty)
    }

    @Test func takesRowsOutInTheFirstPiece() {
        var feed = RowFeed()
        let start = Self.ids(1...10)
        // Past the store's limit: three new at the end, then the oldest three out.
        let change = RowMirror.Change(splices: [
            RowMirror.Splice(position: 10, removing: 0, inserting: Self.ids(11...13)),
            RowMirror.Splice(position: 0, removing: 3, inserting: []),
        ])
        feed.append(change, shown: 10)
        let (rows, pieces) = Self.fed(start, &feed)
        #expect(rows == Self.ids(4...13))
        #expect(pieces.count == 2)
        // And a splice that takes rows out and puts more in, in pieces.
        var replacing = RowFeed()
        replacing.append(
            RowMirror.Change(splices: [RowMirror.Splice(position: 2, removing: 5, inserting: Self.ids(100...2_200))]),
            shown: 10)
        let replaced = Self.fed(start, &replacing)
        #expect(replaced.rows == Self.ids(1...2) + Self.ids(100...2_200) + Self.ids(8...10))
        #expect(replaced.pieces.map(\.removing) == [5, 0])
    }

    @Test func saysWhileEveryRowGoesInAgain() {
        var feed = RowFeed()
        let all = Self.ids(1...5_000)
        feed.append(
            RowMirror.Change(splices: [RowMirror.Splice(position: 0, removing: 10, inserting: all)], isWhole: true),
            shown: 10)
        feed.append(
            RowMirror.Change(splices: [RowMirror.Splice(position: 5_000, removing: 0, inserting: [])]), shown: 10)
        var resetting: [Bool] = []
        while !feed.isEmpty {
            resetting.append(feed.isResetting)
            _ = feed.next()
        }
        // Three pieces of the reset, then the change after it.
        #expect(resetting == [true, true, true, false])
    }

    /// A search typed a character at a time: each character's rows put in every row again, so
    /// the pieces still waiting of the one before go, and the new one takes out what shows.
    @Test func putsInOnlyTheLatestOfEveryRow() {
        var feed = RowFeed()
        let start = Self.ids(1...10_000)
        var rows = start
        let even = Self.ids(1...5_000).filter { $0.rawValue % 2 == 0 }
        feed.append(
            RowMirror.Change(
                splices: [RowMirror.Splice(position: 0, removing: 10_000, inserting: even)], isWhole: true),
            shown: 10_000)
        // One piece in, then the next character's rows come.
        let first = feed.next()
        if let first {
            rows.replaceSubrange(first.position..<first.position + first.removing, with: first.inserting)
        }
        #expect(rows.count == 2_048)
        let latest = Self.ids(1...5_000).filter { $0.rawValue % 4 == 0 }
        feed.append(
            RowMirror.Change(
                splices: [RowMirror.Splice(position: 0, removing: 2_500, inserting: latest)], isWhole: true),
            shown: rows.count)
        let (after, pieces) = Self.fed(rows, &feed)
        #expect(after == latest)
        #expect(pieces.map(\.removing) == [2_048])
        #expect(feed.isEmpty)
    }

    // MARK: - Following

    @Test func followsFromTheEndAndPastTheLimit() {
        var following = Following()
        var follows: Bool
        var result: Following.Reveal
        // At the end, rows come: the newest shows at once.
        follows = following.begin(showsEnd: true)
        #expect(follows)
        result = following.end(inserted: 1, isDone: true, isResetting: false, now: 1_000_000)
        #expect(result == .now)
        // 150 ms later, past the store's limit, as many old rows go as new ones come: the count
        // stays, but rows came in, so it follows.
        follows = following.begin(showsEnd: true)
        #expect(follows)
        result = following.end(inserted: 1, isDone: true, isResetting: false, now: 1_150_000)
        #expect(result == .now)
        // A change with no new rows shows nothing.
        following.begin(showsEnd: true)
        result = following.end(inserted: 0, isDone: true, isResetting: false, now: 1_400_000)
        #expect(result == .none)
    }

    @Test func keepsFollowingRowsThatPushedTheEndAway() {
        var following = Following()
        var follows: Bool
        var result: Following.Reveal
        following.begin(showsEnd: true)
        result = following.end(inserted: 2048, isDone: false, isResetting: false, now: 0)
        #expect(result == .now)
        // More of a burst, too soon after that to show: still following, though the rows put in
        // pushed the end out of view.
        follows = following.begin(showsEnd: true)
        #expect(follows)
        result = following.end(inserted: 2048, isDone: false, isResetting: false, now: 40_000)
        #expect(result == .none)
        #expect(following.hasUnrevealed)
        follows = following.begin(showsEnd: false)
        #expect(follows)
        // Done 60 ms after the reveal: it waits the rest of the 100 ms.
        result = following.end(inserted: 904, isDone: true, isResetting: false, now: 60_000)
        #expect(result == .after(milliseconds: 40))
        result = following.reveal(isDone: true, isResetting: false, now: 100_000)
        #expect(result == .now)
        #expect(!following.hasUnrevealed)
    }

    @Test func stopsAsYouScrollUp() {
        var following = Following()
        var result: Following.Reveal
        var follows: Bool
        following.begin(showsEnd: true)
        result = following.end(inserted: 1, isDone: true, isResetting: false, now: 0)
        #expect(result == .now)
        following.begin(showsEnd: true)
        result = following.end(inserted: 1, isDone: true, isResetting: false, now: 50_000)
        #expect(result == .after(milliseconds: 50))
        // Scrolled up before the newest row's turn: it stays where you scrolled to.
        following.stop()
        #expect(!following.isFollowing && !following.hasUnrevealed)
        result = following.reveal(isDone: true, isResetting: false, now: 100_000)
        #expect(result == .none)
        follows = following.begin(showsEnd: false)
        #expect(!follows)
        // Back at its end, it follows again.
        follows = following.begin(showsEnd: true)
        #expect(follows)
    }

    @Test func doesntFollowAListScrolledUp() {
        var following = Following()
        let follows = following.begin(showsEnd: false)
        #expect(!follows)
        let result = following.end(inserted: 50, isDone: true, isResetting: false, now: 0)
        #expect(result == .none)
        #expect(!following.hasUnrevealed)
    }

    @Test func waitsForEveryRowToGoInAgain() {
        var following = Following()
        var result: Following.Reveal
        following.begin(showsEnd: true)
        result = following.end(inserted: 2048, isDone: false, isResetting: true, now: 0)
        #expect(result == .none)
        following.begin(showsEnd: false)
        result = following.end(inserted: 2048, isDone: false, isResetting: true, now: 200_000)
        #expect(result == .none)
        following.begin(showsEnd: false)
        result = following.end(inserted: 904, isDone: true, isResetting: false, now: 210_000)
        #expect(result == .now)
    }

    // MARK: - Going to the end

    /// As on GitHub's arm64 runner: asked for the newest row again just as the list was at its
    /// end, GTK lays the new last row out in the next frame with its top on the bottom edge, so
    /// the list goes on to its end, rather than taking the frame before that layout as the end.
    @Test func goesOnToARowAskedForAsItWasAtItsEnd() {
        var ending = GoingToTheEnd()
        var steps: [GoingToTheEnd.Step] = []
        let started = ending.ask(now: 0)
        // GTK goes to the row in the first frame's layout.
        steps.append(ending.frame(0, 20_451, at: 16_000))
        steps.append(ending.frame(19_191, 20_451, at: 33_000))
        // 20 more rows, and the list asks again: the frame after is at the end the last layout
        // made, which isn't its end for good.
        let startedAgain = ending.ask(now: 40_000)
        steps.append(ending.frame(20_451, 20_451, at: 50_000))
        // That frame's layout left the newest row, 21 px, below the edge: to the end again.
        steps.append(ending.frame(20_850, 20_871, at: 66_000))
        // At its end, and still there a frame later, everything in: done.
        steps.append(ending.frame(20_871, 20_871, at: 83_000))
        let wasGoing = ending.isGoing
        steps.append(ending.frame(20_871, 20_871, at: 100_000))
        #expect(started && !startedAgain && wasGoing && !ending.isGoing)
        #expect(steps == [.wait, .move(to: 20_451), .wait, .move(to: 20_871), .wait, .stop])
    }

    /// On a slow computer, the end moves for many frames, and the rows' contents come after:
    /// it goes on, frame after frame, until both are done.
    @Test func goesOnWhileTheEndMovesAndTheRowsFillIn() {
        var ending = GoingToTheEnd()
        _ = ending.ask(now: 0)
        var steps = [ending.frame(0, 1_000, at: 16_000)]
        var expected: [GoingToTheEnd.Step] = [.wait]
        var end = 1_000.0
        var now = 16_000
        for _ in 0..<20 {
            now += 50_000
            steps.append(ending.frame(end - 21, end, at: now))
            expected.append(.move(to: end))
            end += 21
        }
        for isSettled in [false, false, true] {
            now += 50_000
            steps.append(ending.frame(end, end, at: now, isSettled: isSettled))
            expected.append(.wait)
        }
        steps.append(ending.frame(end, end, at: now + 50_000))
        expected.append(.stop)
        #expect(steps == expected)
    }

    /// Rows that come after the list asked push its end out, but wait for their own turn to show,
    /// as the list asks again once it's time: it doesn't move for them meanwhile, nor take a frame
    /// at its old end as done.
    @Test func leavesRowsAfterTheAskForTheirTurn() {
        var ending = GoingToTheEnd()
        _ = ending.ask(now: 0)
        var steps = [ending.frame(0, 1_000, at: 16_000), ending.frame(979, 1_000, at: 33_000)]
        // 50 rows more, 30 ms after the ask: their turn is at 100 ms.
        steps.append(ending.frame(1_000, 2_050, at: 50_000, hasNewRows: true))
        steps.append(ending.frame(1_000, 2_050, at: 66_000, hasNewRows: true))
        steps.append(ending.frame(1_000, 2_050, at: 83_000, hasNewRows: true))
        let wasGoing = ending.isGoing
        let startedAgain = ending.ask(now: 100_000)
        steps.append(ending.frame(1_000, 2_050, at: 116_000))
        steps.append(ending.frame(1_200, 2_050, at: 133_000))
        steps.append(ending.frame(2_050, 2_050, at: 150_000))
        steps.append(ending.frame(2_050, 2_050, at: 166_000))
        #expect(wasGoing && !startedAgain)
        #expect(steps == [.wait, .move(to: 1_000), .wait, .wait, .wait, .wait, .move(to: 2_050), .wait, .stop])
    }

    /// It gives up 2 s after the list last asked for its newest row, however many frames that is.
    @Test func givesUpAfterAWhile() {
        var ending = GoingToTheEnd()
        _ = ending.ask(now: 0)
        var steps = [ending.frame(0, 500, at: 16_000), ending.frame(0, 500, at: 1_000_000)]
        // Asked again, it goes on 2 s from then.
        let startedAgain = ending.ask(now: 1_500_000)
        steps += [ending.frame(500, 600, at: 1_516_000), ending.frame(500, 600, at: 3_000_000)]
        steps.append(ending.frame(600, 700, at: 3_500_000))
        let wasGoing = ending.isGoing
        // The next time, it starts again.
        let startsNextTime = ending.ask(now: 4_000_000)
        #expect(!startedAgain && !wasGoing && startsNextTime)
        #expect(steps == [.wait, .move(to: 500), .wait, .move(to: 600), .stop])
    }

    /// Scrolled up from where it left the list, as a finger drags it, or no longer following, as
    /// the keys, the wheel and the scrollbar stop it, it stops; and stopped, a frame callback of
    /// an earlier time sees it's over.
    @Test func stopsAsYouScroll() {
        var ending = GoingToTheEnd()
        _ = ending.ask(now: 0)
        let round = ending.round
        var steps = [ending.frame(0, 1_000, at: 16_000), ending.frame(400, 1_000, at: 33_000)]
        steps.append(ending.frame(900, 1_000, at: 50_000))
        #expect(!ending.isGoing && ending.round != round)
        // Found at its end, then dragged up a little.
        _ = ending.ask(now: 100_000)
        steps.append(ending.frame(1_000, 1_000, at: 116_000))
        steps.append(ending.frame(1_000, 1_000, at: 133_000, isSettled: false))
        steps.append(ending.frame(990, 1_000, at: 150_000, isSettled: false))
        // No longer following.
        _ = ending.ask(now: 200_000)
        steps.append(ending.frame(0, 1_000, at: 216_000))
        steps.append(ending.frame(0, 1_000, at: 233_000, isFollowing: false))
        #expect(steps == [.wait, .move(to: 1_000), .stop, .wait, .wait, .stop, .wait, .stop])
        // Stopped by the list.
        _ = ending.ask(now: 300_000)
        let started = ending.round
        ending.stop()
        let isGoing = ending.isGoing
        let step = ending.frame(0, 1_000, at: 316_000)
        #expect(!isGoing && ending.round != started && step == .stop)
    }

    // MARK: - The rows' contents

    static func summary(_ id: UInt64) -> ExchangeSummary {
        var summary = RowTextTests.summary()
        summary.id = ExchangeID(rawValue: id)
        return summary
    }

    @Test func asksOnlyForRowsThatAreBound() {
        var cache = SummaryCache(locale: RowTextTests.english, timeZone: RowTextTests.utc)
        // 100,000 rows arrive; none is asked for.
        cache.inserted(Self.ids(1...100_000))
        #expect(!cache.hasWanted)
        // GTK binds 30 of them, each in seven cells: each is asked for once, together.
        for id in Self.ids(99_971...100_000) {
            for _ in 0..<7 {
                let entry = cache.bound(id)
                #expect(entry == nil)
            }
        }
        let wanted = cache.takeWanted()
        #expect(wanted == Self.ids(99_971...100_000))
        #expect(!cache.hasWanted)
        let bound = Set(wanted)
        let filled = cache.received(wanted.map { Self.summary($0.rawValue) }) { bound.contains($0) }
        #expect(filled.count == 30)
        let newest = cache.bound(ExchangeID(rawValue: 100_000))
        #expect(newest?.text.status == "200")
        #expect(!cache.hasWanted)
    }

    @Test func asksAgainOnlyForChangedRowsOnScreen() {
        var cache = SummaryCache()
        let shown = Set(Self.ids(1...2))
        _ = cache.received([Self.summary(1), Self.summary(2), Self.summary(3)]) { _ in true }
        cache.changed(Self.ids(1...3)) { shown.contains($0) }
        // The ones on screen keep what they show until the new contents come.
        let wanted = cache.takeWanted()
        #expect(wanted == Self.ids(1...2))
        #expect(cache[ExchangeID(rawValue: 1)] != nil)
        #expect(cache[ExchangeID(rawValue: 3)] == nil)
        // A row that comes back, as a filter lets it through again, is asked for again.
        cache.inserted(Self.ids(2...2))
        #expect(cache[ExchangeID(rawValue: 2)] == nil)
        cache.forgetAll()
        #expect(cache.count == 0)
    }

    @Test func keepsOnlyBoundRowsPastItsLimit() {
        var cache = SummaryCache()
        let all = (1...UInt64(SummaryCache.kept + 1)).map(Self.summary)
        // All bound, as a tall window would have them.
        _ = cache.received(all) { _ in true }
        #expect(cache.count == SummaryCache.kept + 1)
        _ = cache.received([Self.summary(1)]) { $0.rawValue <= 10 }
        #expect(cache.count == 10)
    }

    @Test func showsAPinAtOnce() {
        var cache = SummaryCache()
        _ = cache.received([Self.summary(1)]) { _ in true }
        let pinned = cache.update(ExchangeID(rawValue: 1)) { $0.annotation.isPinned = true }
        #expect(pinned?.text.isPinned == true)
        let missing = cache.update(ExchangeID(rawValue: 2)) { $0.annotation.isPinned = true }
        #expect(missing == nil)
    }
}

extension GoingToTheEnd {
    /// A frame of a list that follows, with no rows since it asked, and every change and the rows'
    /// contents in, unless said.
    fileprivate mutating func frame(
        _ value: Double, _ end: Double, at now: Int, isSettled: Bool = true, isFollowing: Bool = true,
        hasNewRows: Bool = false
    ) -> Step {
        frame(
            value: value, end: end, isFollowing: isFollowing, hasNewRows: hasNewRows, isSettled: isSettled, now: now)
    }
}
