import Presentation
import Testing

@Suite struct QueryParametersTests {
    func pairs(_ query: String) -> [String] {
        QueryParameters.parse(query).map { "\($0.name)=\($0.value)" }
    }

    @Test func decodesEachPairInOrder() {
        #expect(pairs("city=Tehran&units=metric&city=Oslo") == ["city=Tehran", "units=metric", "city=Oslo"])
        #expect(pairs("q=caf%C3%A9+au+lait&bad=%ZZ") == ["q=café+au+lait", "bad=%ZZ"])
        #expect(pairs("flag&&empty=") == ["flag=", "empty="])
    }

    @Test func keepsEmptyNamesWithoutStopping() {
        // A lone "=" once stopped the Mac app's Request tab.
        #expect(pairs("a=1&=&=x") == ["a=1", "=", "=x"])
    }
}
