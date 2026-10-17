import Foundation
import Presentation
import ReqlyModel
import Testing

@Suite struct RawMessageTests {
    @Test func writesTheRequestAsHTTP11DoesWithSecretsHidden() {
        let request = RequestHead(
            method: "POST", scheme: "https", host: "api.weatherly.dev", port: 443, target: "/v2/report",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer abc"])
        let raw = RawMessage(request: request, body: Data(#"{"sky":"clear"}"#.utf8), hidingSecrets: true)
        #expect(
            raw.text.hasPrefix("POST /v2/report HTTP/1.1\nContent-Type: application/json\nAuthorization: ••••••••\n\n"))
        #expect(raw.text.hasSuffix(#"{"sky":"clear"}"# + "\n"))
        let shown = RawMessage(request: request, body: Data(), hidingSecrets: false)
        #expect(shown.text.contains("Authorization: Bearer abc"))
        #expect(shown.tokens.count == 2)
    }

    @Test func saysWhatABodyIsWhenItIsntText() {
        let response = ResponseHead(status: 200, reason: "OK", headers: ["Content-Encoding": "gzip"])
        let raw = RawMessage(response: response, body: Data(count: 1500), trailers: nil, hidingSecrets: true)
        // The size follows the locale, such as 1.5 KB or 1,5 KB.
        #expect(raw.text.hasSuffix(" KB of gzip-compressed data. The Response tab shows it unpacked.›\n"))
        #expect(raw.text.hasPrefix("HTTP/1.1 200 OK\nContent-Encoding: gzip\n\n‹1"))
    }
}
