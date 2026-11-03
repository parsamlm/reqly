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
        feed.append(RowMirror.Change(splices: [RowMirror.Splice(position: 0, removing: 0, inserting: burst)]))
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
        feed.append(change)
        let (rows, pieces) = Self.fed(start, &feed)
        #expect(rows == Self.ids(4...13))
        #expect(pieces.count == 2)
        // And a splice that takes rows out and puts more in, in pieces.
        var replacing = RowFeed()
        replacing.append(
            RowMirror.Change(splices: [RowMirror.Splice(position: 2, removing: 5, inserting: Self.ids(100...2_200))]))
        let replaced = Self.fed(start, &replacing)
        #expect(replaced.rows == Self.ids(1...2) + Self.ids(100...2_200) + Self.ids(8...10))
        #expect(replaced.pieces.map(\.removing) == [5, 0])
    }

    @Test func saysWhileEveryRowGoesInAgain() {
        var feed = RowFeed()
        let all = Self.ids(1...5_000)
        feed.append(
            RowMirror.Change(splices: [RowMirror.Splice(position: 0, removing: 10, inserting: all)], isReset: true))
        feed.append(RowMirror.Change(splices: [RowMirror.Splice(position: 5_000, removing: 0, inserting: [])]))
        var resetting: [Bool] = []
        while !feed.isEmpty {
            resetting.append(feed.isResetting)
            _ = feed.next()
        }
        // Three pieces of the reset, then the change after it.
        #expect(resetting == [true, true, true, false])
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
