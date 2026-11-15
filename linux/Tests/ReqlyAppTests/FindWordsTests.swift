import Foundation
import ReqlyModel
import Testing

@testable import ReqlyApp

@Suite struct FindWordsTests {
    static let english = Locale(identifier: "en_US")

    @Test func namesTheStatusesAndContentTypesAsTheMacDoes() {
        #expect(StatusFilter.allCases.map(\.title) == ["2xx", "3xx", "4xx", "5xx", "Failed"])
        #expect(StatusFilter.clientError.tip == "Show client errors (4xx)")
        #expect(StatusFilter.failed.tip == "Show requests that failed")
        #expect(
            ContentGroup.allCases.map(\.title) == [
                "JSON", "XML", "HTML", "JavaScript", "CSS", "Images", "Media", "Other",
            ])
    }

    /// A narrow window's status menu: a short label, and every status chosen for screen readers,
    /// in the buttons' order; each status's action has a name of its own.
    @Test func namesTheStatusMenu() {
        let words = { (statuses: Set<StatusFilter>) -> [String] in
            let menu = StatusMenuWords(statuses)
            return [menu.label, menu.name]
        }
        #expect(words([]) == ["All Statuses", "Statuses: all"])
        #expect(words([.clientError]) == ["4xx", "Statuses: 4xx"])
        #expect(words([.failed, .success, .serverError]) == ["3 Statuses", "Statuses: 2xx, 5xx and Failed"])
        #expect(
            StatusFilter.allCases.map(\.actionName) == [
                "status-2xx", "status-3xx", "status-4xx", "status-5xx", "status-failed",
            ])
    }

    @Test func givesEachFilterThatsSetAToken() {
        var filter = TrafficFilter()
        #expect(FilterToken.tokens(for: filter).isEmpty)
        // The statuses have their buttons, not tokens.
        filter.statuses = [.success, .failed]
        #expect(FilterToken.tokens(for: filter).isEmpty)
        filter.source = Source(name: "Firefox", bundleID: "org.mozilla.firefox")
        filter.host = "api.example.com"
        filter.method = "POST"
        filter.contents = [.image, .json]
        let tokens = FilterToken.tokens(for: filter)
        #expect(tokens.map(\.kind) == [.app, .host, .method, .contents])
        #expect(tokens.map(\.title) == ["Firefox", "api.example.com", "POST", "JSON or Images"])
        #expect(tokens[1].removal == "Remove Host Filter")
        #expect(tokens[3].removal == "Remove Content Type Filter")
        #expect(tokens[1].tip == "Host: api.example.com")
        #expect(tokens[3].tip == "Content type: JSON or Images")

        // Each takes off its own filter, and no other.
        var cleared = filter
        tokens[1].clear(&cleared)
        #expect(cleared.host == nil && cleared.method == "POST" && cleared.source != nil)
        tokens[3].clear(&cleared)
        #expect(cleared.contents.isEmpty && cleared.statuses == [.success, .failed])
        tokens[0].clear(&cleared)
        tokens[2].clear(&cleared)
        #expect(FilterToken.tokens(for: cleared).isEmpty && cleared.isActive)
    }

    @Test func joinsTheContentTypesInThePopoversOrder() {
        #expect(FilterToken.contents([.json]) == "JSON")
        #expect(FilterToken.contents([.other, .json]) == "JSON or Other")
        #expect(FilterToken.contents([.image, .xml, .json]) == "JSON, XML or Images")
        #expect(FilterToken.contents([]) == "")
    }

    @Test func foldsTheTokensIntoOne() {
        let tokens = [FilterToken(kind: .host, title: "api.example.com"), FilterToken(kind: .method, title: "GET")]
        let folded = FoldedTokens(tokens: tokens)
        #expect(folded.title == "2 filters")
        #expect(folded.removal == "Remove 2 Filters")
        #expect(folded.tip == "Host: api.example.com\nMethod: GET")
        #expect(folded.spoken == "Host: api.example.com, Method: GET")
        let one = FoldedTokens(tokens: [tokens[0]])
        #expect(one.title == "1 filter" && one.removal == "Remove 1 Filter")
    }

    @Test func saysWhatLeftNothingToShow() {
        let filtered = NoMatches(query: "", filtersAreSet: true)
        #expect(filtered.title == "No Matching Requests")
        #expect(filtered.description == "No requests match the filters.")
        #expect(filtered.clearsFilters)
        let both = NoMatches(query: "tehran", filtersAreSet: true)
        #expect(both.title == "No Results for “tehran”")
        #expect(both.description == "No requests match both the search and the filters.")
        #expect(both.clearsFilters)
        let searched = NoMatches(query: "tehran", filtersAreSet: false)
        #expect(searched.title == "No Results for “tehran”")
        #expect(searched.description == "Check the spelling or try a new search.")
        #expect(!searched.clearsFilters)
        // A scope with none, such as Pinned once nothing is.
        let scoped = NoMatches(query: "", filtersAreSet: false)
        #expect(scoped.title == "No Requests" && !scoped.clearsFilters)
    }

    /// The status buttons' dots are the list's, Reqly teal for 2xx in each style.
    @MainActor @Test func colorsTheDotsForEachStyle() {
        #expect(
            ListStyles.css(ListStyles.light).contains(
                ".request-dot.status-2xx { background-color: #0B9A83; color: #0B9A83; }"))
        #expect(ListStyles.css(ListStyles.dark).contains("#3FDDC0"))
        #expect(ListStyles.css(ListStyles.lightContrast).contains("#056B5A"))
        #expect(ListStyles.css(ListStyles.darkContrast).contains("#71F2D8"))
        #expect(ListStyles.css(ListStyles.light).contains(".request-dot.status-5xx { background-color: #c01c28;"))
    }
}
