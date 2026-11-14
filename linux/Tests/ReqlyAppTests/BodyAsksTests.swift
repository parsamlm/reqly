import Testing

@testable import ReqlyApp

/// When the details ask for a body's presentation as it grows, without a window.
@Suite struct BodyAsksTests {
    /// Each step's answers: whether to ask, for `want` with a size, or for `landed` with `nil`.
    static func asks(_ steps: [Int?], from start: BodyAsks = BodyAsks()) -> (answers: [Bool], asks: BodyAsks) {
        var asks = start
        let answers = steps.map { size in size.map { asks.want($0) } ?? asks.landed() }
        return (answers, asks)
    }

    @Test func asksOnceForEachSize() {
        let (answers, asks) = Self.asks([100, nil, 100, 200])
        #expect(answers == [true, false, false, true])
        #expect(asks.isAsking)
    }

    /// A body that grows faster than it's presented: no second ask while one is on its way, so no
    /// older presentation can land after a newer one; once it lands, one ask for the size then.
    @Test func asksOneAtATimeAsTheBodyGrows() {
        let (answers, asks) = Self.asks([100, 200, 300, nil, 300, nil])
        #expect(answers == [true, false, false, true, false, false])
        #expect(!asks.isAsking)
    }

    /// The body went back to the size on its way meanwhile: nothing more to ask.
    @Test func asksNothingMoreForTheSizeOnItsWay() {
        let (answers, _) = Self.asks([100, 200, 100, nil])
        #expect(answers == [true, false, false, false])
    }

    /// A new view needs a presentation of its own, even of a body that hasn't grown.
    @Test func asksAgainForANewView() {
        var (answers, asks) = Self.asks([100, nil])
        asks.forget()
        (answers, asks) = Self.asks([100], from: asks)
        #expect(answers == [true])
        asks.forget()
        (answers, _) = Self.asks([100, nil], from: asks)
        #expect(answers == [false, true])
    }
}
