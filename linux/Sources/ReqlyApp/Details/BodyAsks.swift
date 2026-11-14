/// When the details ask the session to present a part's body: once for each size the page has it
/// at, and one at a time, so each presentation lands after the one before and shows, newer than
/// what shows. As a body grows faster than it's presented, the sizes it had meanwhile are skipped:
/// once a presentation lands, the next is asked for the size the page has then.
struct BodyAsks {
    /// The size the page has the body at, and the size last asked for.
    private var wanted: Int?
    private var asked: Int?
    /// Whether a presentation is on its way.
    private(set) var isAsking = false

    /// The page has the body at `size`. Whether to ask for a presentation now.
    mutating func want(_ size: Int) -> Bool {
        wanted = size
        return askNext()
    }

    /// The presentation asked for landed, or failed. Whether to ask again, as the body grew
    /// meanwhile.
    mutating func landed() -> Bool {
        isAsking = false
        return askNext()
    }

    /// The body has a new view, which needs a presentation even at the size last asked for.
    mutating func forget() {
        asked = nil
    }

    private mutating func askNext() -> Bool {
        guard !isAsking, let wanted, wanted != asked else { return false }
        asked = wanted
        isAsking = true
        return true
    }
}
