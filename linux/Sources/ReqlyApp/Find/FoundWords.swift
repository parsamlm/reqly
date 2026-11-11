/// When screen readers hear what a search or the filters found, as the window tells it what
/// happens, in monotonic microseconds. Once the list has settled, and its count has stayed the
/// same for half a second, as the store's matches in headers and bodies come a while after the
/// list's own; then once more if the count changes within 3 seconds of that, as when the store's
/// matches came later still, or new traffic matches. At most twice for each change of the search
/// or the filters, and each at most 2 seconds after what it waits on, however the rows change.
struct FoundWords {
    /// How long the list's count stays the same before it's said.
    static let quiet = 500_000
    /// The longest it waits, for the count to stay the same or the list to settle.
    static let longest = 2_000_000
    /// How long after it's said a change to the count is said again.
    static let later = 3_000_000
    /// How soon it looks again while the list is still settling.
    static let again = 100_000

    /// When to say what's found, while it waits to.
    private(set) var due: Int?
    /// When it started waiting.
    private var since = 0
    /// The list's count, as it last heard.
    private var count = 0
    /// When it was said last, and how many times since the search or the filters changed.
    private var saidAt: Int?
    private var times = 0

    /// The search or the filters changed, and the list shows `count` rows.
    mutating func changed(count: Int, at now: Int) {
        self.count = count
        saidAt = nil
        times = 0
        wait(from: now)
    }

    /// The list's rows changed, and it shows `count`.
    mutating func rowsChanged(count: Int, at now: Int) {
        guard count != self.count else { return }
        self.count = count
        if due != nil {
            due = min(now + Self.quiet, since + Self.longest)
        } else if let saidAt, times < 2, now - saidAt < Self.later {
            wait(from: now)
        }
    }

    /// Whether to say it now, with the list `settled` or not. If not, ``due`` says when to look
    /// again, while it still waits.
    mutating func isDue(at now: Int, settled: Bool) -> Bool {
        guard let due, now >= due else { return false }
        if !settled, now < since + Self.longest {
            self.due = min(now + Self.again, since + Self.longest)
            return false
        }
        self.due = nil
        saidAt = now
        times += 1
        return true
    }

    private mutating func wait(from now: Int) {
        since = now
        due = now + Self.quiet
    }
}
