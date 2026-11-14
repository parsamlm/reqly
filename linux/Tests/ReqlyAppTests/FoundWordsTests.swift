import Testing

@testable import ReqlyApp

@Suite struct FoundWordsTests {
    static let ms = 1_000

    /// Runs the clock from `start` to `end` a millisecond at a time, as the window's timer looks,
    /// and gives when it was said.
    static func said(_ found: inout FoundWords, from start: Int, to end: Int, settled: Bool = true) -> [Int] {
        var times: [Int] = []
        for now in stride(from: start, through: end, by: ms) where found.isDue(at: now, settled: settled) {
            times.append(now)
        }
        return times
    }

    @Test func saysItHalfASecondAfterTheLastChange() {
        var found = FoundWords()
        found.changed(count: 6, at: 0)
        found.rowsChanged(count: 2, at: 20 * Self.ms)
        #expect(Self.said(&found, from: 0, to: 3_000 * Self.ms) == [520 * Self.ms])
    }

    /// The store's matches, after the list's own count was said: said again, once.
    @Test func saysItAgainWhenTheCountChangesSoonAfter() {
        var found = FoundWords()
        found.changed(count: 0, at: 0)
        #expect(Self.said(&found, from: 0, to: 600 * Self.ms) == [500 * Self.ms])
        found.rowsChanged(count: 47_500, at: 900 * Self.ms)
        #expect(Self.said(&found, from: 600 * Self.ms, to: 5_000 * Self.ms) == [1_400 * Self.ms])
        // Not a third time, nor once it's been 3 seconds.
        found.rowsChanged(count: 47_501, at: 1_500 * Self.ms)
        #expect(found.due == nil)
        var later = FoundWords()
        later.changed(count: 0, at: 0)
        _ = Self.said(&later, from: 0, to: 600 * Self.ms)
        later.rowsChanged(count: 5, at: 3_600 * Self.ms)
        #expect(later.due == nil)
    }

    /// Matching traffic that never stops changes the count: said at most 2 seconds after each
    /// change it waits on, and twice in all.
    @Test func waitsNoLongerThanTwoSecondsAndSaysItTwiceAtMost() {
        var found = FoundWords()
        found.changed(count: 0, at: 0)
        var times: [Int] = []
        for now in stride(from: 0, through: 10_000 * Self.ms, by: Self.ms) {
            if now % (100 * Self.ms) == 0 {
                found.rowsChanged(count: now / Self.ms, at: now)
            }
            if found.isDue(at: now, settled: true) {
                times.append(now)
            }
        }
        #expect(times == [2_000 * Self.ms, 4_100 * Self.ms])
    }

    /// While the list is still putting rows in, it waits for it, up to 2 seconds.
    @Test func waitsForTheListToSettle() {
        var found = FoundWords()
        found.changed(count: 0, at: 0)
        #expect(Self.said(&found, from: 0, to: 800 * Self.ms, settled: false).isEmpty)
        #expect(found.due == 900 * Self.ms)
        #expect(Self.said(&found, from: 800 * Self.ms, to: 3_000 * Self.ms) == [900 * Self.ms])
        var unsettled = FoundWords()
        unsettled.changed(count: 0, at: 0)
        #expect(Self.said(&unsettled, from: 0, to: 3_000 * Self.ms, settled: false) == [2_000 * Self.ms])
    }

    /// A new search or filter starts again, with nothing said yet.
    @Test func startsAgainWithEachChange() {
        var found = FoundWords()
        found.changed(count: 6, at: 0)
        found.changed(count: 6, at: 200 * Self.ms)
        found.changed(count: 6, at: 400 * Self.ms)
        #expect(Self.said(&found, from: 0, to: 2_000 * Self.ms) == [900 * Self.ms])
        found.changed(count: 2, at: 2_000 * Self.ms)
        found.rowsChanged(count: 3, at: 2_100 * Self.ms)
        #expect(Self.said(&found, from: 2_000 * Self.ms, to: 4_000 * Self.ms) == [2_600 * Self.ms])
    }
}
