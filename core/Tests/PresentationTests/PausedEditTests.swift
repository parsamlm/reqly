import Foundation
import Presentation
import ReqlyModel
import Testing

@Suite struct PausedEditTests {
    let request = RequestHead(
        method: "POST", scheme: "https", host: "api.weatherly.dev", port: 443, target: "/v2/report",
        headers: ["Host": "api.weatherly.dev", "Content-Type": "application/json", "Content-Length": "15"])
    let body = Data(#"{"sky":"clear"}"#.utf8)

    @Test func showsJSONLaidOutAndHidesFramingHeaders() {
        let edit = PausedEdit(.request(request, body: body), breakpoint: "Reports")
        #expect(edit.headers.map(\.name) == ["Host", "Content-Type"])
        #expect(edit.body.contains("\n") || edit.body.contains(": "))
        #expect(edit.url == "https://api.weatherly.dev/v2/report")
    }

    @Test func sendsTheBytesAsTheyCameUnlessTheTextChanged() throws {
        let edit = PausedEdit(.request(request, body: body), breakpoint: "Reports")
        guard case .request(_, let unchanged) = try edit.edited() else { Issue.record("not a request"); return }
        #expect(unchanged == body)
        var changed = edit
        changed.body = #"{"sky":"rain"}"#
        guard case .request(_, let edited) = try changed.edited() else { Issue.record("not a request"); return }
        #expect(edited == Data(#"{"sky":"rain"}"#.utf8))
    }

    @Test func movesTheHostHeaderWithTheURL() throws {
        var edit = PausedEdit(.request(request, body: body), breakpoint: "Reports")
        edit.url = "http://staging.weatherly.dev:8080/v2/report?draft=1"
        guard case .request(let head, _) = try edit.edited() else { Issue.record("not a request"); return }
        #expect(head.scheme == "http" && head.host == "staging.weatherly.dev" && head.port == 8080)
        #expect(head.target == "/v2/report?draft=1")
        #expect(head.headers["Host"] == "staging.weatherly.dev:8080")
    }

    @Test func saysWhatToFix() {
        var edit = PausedEdit(.request(request, body: body), breakpoint: "Reports")
        edit.url = "ftp://example.com"
        #expect(throws: PausedEdit.Problem.url) { try edit.edited() }
        let head = ResponseHead(status: 200, reason: "OK")
        var response = PausedEdit(.response(head, body: Data()), breakpoint: "Reports")
        response.status = "600"
        #expect(throws: PausedEdit.Problem.status) { try response.edited() }
        #expect(PausedEdit.Problem.status.message == "Enter a status from 100 to 599.")
    }
}
