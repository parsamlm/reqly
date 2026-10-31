import CoreInterface
import ReqlyModel
import Testing

@testable import ReqlyApp

@Suite struct RowMirrorTests {
    static func ids(_ numbers: [UInt64]) -> [ExchangeID] {
        numbers.map(ExchangeID.init(rawValue:))
    }

    static func inserted(_ rows: [(Int, UInt64)]) -> RowStep {
        .inserted(rows.map { RowStep.InsertedRow(row: $0.0, id: ExchangeID(rawValue: $0.1)) })
    }

    /// The rows a GtkStringList ends with after the splices.
    static func spliced(_ start: [ExchangeID], _ splices: [RowMirror.Splice]) -> [ExchangeID] {
        var rows = start
        for splice in splices {
            rows.replaceSubrange(splice.position..<splice.position + splice.removing, with: splice.inserting)
        }
        return rows
    }

    @Test func appliesEachEventsStepsInOrder() throws {
        var mirror = RowMirror()
        var shown: [ExchangeID] = []
        let received = mirror.receive(version: 1, steps: [Self.inserted([(0, 1), (1, 2), (2, 3)])])
        let first = try #require(received)
        #expect(first.splices == [RowMirror.Splice(position: 0, removing: 0, inserting: Self.ids([1, 2, 3]))])
        #expect(first.inserted == Self.ids([1, 2, 3]))
        shown = Self.spliced(shown, first.splices)

        // Rows 0 and 2 go, then two come, one between and one at the end.
        let steps: [RowStep] = [.removed([0, 2]), Self.inserted([(1, 4), (2, 5)]), .changed(Self.ids([2]))]
        let next = mirror.receive(version: 2, steps: steps)
        let second = try #require(next)
        shown = Self.spliced(shown, second.splices)
        #expect(mirror.ids == Self.ids([2, 4, 5]))
        #expect(shown == mirror.ids)
        #expect(second.changed == Self.ids([2]))
        #expect(second.inserted == Self.ids([4, 5]))
        #expect(mirror.members == Set(Self.ids([2, 4, 5])))
        #expect(mirror.version == 2)
    }

    @Test func removesARunOfNeighborsInOneSplice() throws {
        var mirror = RowMirror()
        _ = mirror.receive(version: 1, steps: [.reset(Self.ids([1, 2, 3, 4, 5, 6]))])
        let received = mirror.receive(version: 2, steps: [.removed([1, 2, 3, 5])])
        let change = try #require(received)
        #expect(
            change.splices == [
                RowMirror.Splice(position: 5, removing: 1, inserting: []),
                RowMirror.Splice(position: 1, removing: 3, inserting: []),
            ])
        #expect(mirror.ids == Self.ids([1, 5]))
    }

    @Test func waitsForEveryRowWhenAnEventIsMissing() throws {
        var mirror = RowMirror()
        _ = mirror.receive(version: 1, steps: [Self.inserted([(0, 1)])])
        // Version 2 never came.
        #expect(mirror.receive(version: 3, steps: [Self.inserted([(1, 3)])]) == nil)
        #expect(mirror.isWaitingForRows)
        // What comes while it waits is kept.
        #expect(mirror.receive(version: 4, steps: [Self.inserted([(2, 4)])]) == nil)
        #expect(mirror.receive(version: 5, steps: [.removed([0])]) == nil)

        // Every row as of version 4: the event for 3 and 4 are in it, and 5 follows.
        let change = mirror.reset(version: 4, ids: Self.ids([1, 2, 3, 4]))
        #expect(!mirror.isWaitingForRows)
        #expect(Self.spliced(Self.ids([1]), change.splices) == Self.ids([2, 3, 4]))
        #expect(mirror.ids == Self.ids([2, 3, 4]))
        #expect(mirror.version == 5)
    }

    @Test func waitsForEveryRowWhenAStepDoesntFit() {
        var mirror = RowMirror()
        _ = mirror.receive(version: 1, steps: [Self.inserted([(0, 1)])])
        #expect(mirror.receive(version: 2, steps: [.removed([3])]) == nil)
        #expect(mirror.isWaitingForRows)
        #expect(mirror.ids == Self.ids([1]))
    }

    @Test func leavesOutEventsTheRowsAlreadyHave() {
        var mirror = RowMirror()
        _ = mirror.reset(version: 7, ids: Self.ids([1, 2]))
        #expect(mirror.receive(version: 6, steps: [.removed([0])]) == nil)
        #expect(!mirror.isWaitingForRows)
        #expect(mirror.ids == Self.ids([1, 2]))
    }

    @Test func takesEveryRowAtOnce() throws {
        var mirror = RowMirror()
        _ = mirror.receive(version: 1, steps: [Self.inserted([(0, 1), (1, 2)])])
        let received = mirror.receive(version: 2, steps: [.reset(Self.ids([7, 8, 9]))])
        let change = try #require(received)
        #expect(change.splices == [RowMirror.Splice(position: 0, removing: 2, inserting: Self.ids([7, 8, 9]))])
        #expect(mirror.members == Set(Self.ids([7, 8, 9])))
    }
}
