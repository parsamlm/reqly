import Foundation
import Testing

@testable import ReqlyApp

/// The self-check's traffic maker, with no Reqly between: its server answers each path as its
/// parts expect, and its client keeps connections open across a burst.
@Suite struct TrafficMakerTests {
    /// One request on a connection of its own, straight to the server.
    static func ask(_ server: TestServer, _ target: String, headers: String = "") throws -> ProxyClient.Response? {
        let wire = HTTPWire(try Loopback.connect(to: server.port))
        defer { close(wire.socket) }
        let request = "GET \(target) HTTP/1.1\r\nHost: \(server.origin)\r\n\(headers)Connection: close\r\n\r\n"
        guard wire.write(Array(request.utf8)) else { return nil }
        return wire.response()
    }

    @Test func answersEachPath() throws {
        let server = try TestServer()
        defer { server.stop() }
        let json = try #require(try Self.ask(server, "/json"))
        #expect(json.status == 200 && HTTPWire.value("content-type", in: json.headers) == "application/json")
        #expect(json.text.hasPrefix(#"{"city":"Tehran""#))
        let packed = try #require(try Self.ask(server, "/gzip"))
        #expect(packed.body == TestServer.packedJSON)
        #expect(HTTPWire.value("Content-Encoding", in: packed.headers) == "gzip")
        let image = try #require(try Self.ask(server, "/image.png"))
        #expect(image.body == TestServer.png && image.body.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let cookies = try #require(try Self.ask(server, "/cookies"))
        #expect(cookies.headers.filter { $0.name == "Set-Cookie" }.count == 2)
        #expect(try Self.ask(server, "/me")?.status == 401)
        #expect(try Self.ask(server, "/me", headers: "Authorization: Bearer x\r\n")?.status == 200)
        #expect(try Self.ask(server, "/big?bytes=5000")?.body.count == 5000)
        #expect(try Self.ask(server, "/json?status=503")?.status == 503)
        // A proxy's full URL counts from its path.
        let text = try Self.ask(server, "http://\(server.origin)/text")?.text
        #expect(text == "Clear skies over Tehran.\nRain tomorrow.\n")
        // No answer at all, as a server that fails.
        #expect(try Self.ask(server, "/fail") == nil)
    }

    @Test func waitsWhenAsked() throws {
        let server = try TestServer()
        defer { server.stop() }
        let started = Date()
        #expect(try Self.ask(server, "/slow?ms=200")?.text == "At last.")
        #expect(Date().timeIntervalSince(started) >= 0.2)
    }

    /// A burst keeps each connection open for its next request, so 300 go on 4 connections.
    @Test func sendsABurst() async throws {
        let server = try TestServer()
        defer { server.stop() }
        let client = ProxyClient(proxyPort: server.port)
        let paths: [TestServer.Path] = [.json, .xml, .form, .me]
        let burst = await client.burst((0..<300).map { server.url(paths[$0 % paths.count]) }, connections: 4)
        #expect(burst.sent == 300 && burst.answered == 300 && burst.problems.isEmpty)
        #expect(burst.statuses == [200: 225, 401: 75])
        let one = try await client.send(server.url(.html), method: "POST", body: Array("city=Tehran".utf8))
        #expect(one.status == 200 && one.text.contains("<h1>Tehran</h1>"))
    }

    /// Bodies sent in chunks, as Reqly may pass a response on, read whole.
    @Test func readsChunks() throws {
        var ends: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &ends) == 0)
        defer { close(ends[1]) }
        let wire = HTTPWire(ends[0])
        defer { close(ends[0]) }
        let response =
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + "5\r\nhello\r\n7;x=1\r\n, Reqly\r\n0\r\n\r\n"
        #expect(HTTPWire(ends[1]).write(Array(response.utf8)))
        let read = try #require(wire.response())
        #expect(read.status == 200 && read.text == "hello, Reqly")
    }
}
