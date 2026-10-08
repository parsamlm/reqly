import Testing

@testable import ProxyEngine

@Suite struct TargetTests {
    @Test func readsAbsoluteFormTargets() throws {
        let target = try #require(ProxyTarget(absoluteForm: "http://api.weatherly.dev/v2/forecast?city=amsterdam"))
        #expect(target.authority == Authority(host: "api.weatherly.dev", port: 80))
        #expect(target.originForm == "/v2/forecast?city=amsterdam")
    }

    @Test func fillsInAMissingPath() throws {
        #expect(ProxyTarget(absoluteForm: "http://Example.COM:8080")?.originForm == "/")
        #expect(ProxyTarget(absoluteForm: "http://example.com?q=1")?.originForm == "/?q=1")
        #expect(
            ProxyTarget(absoluteForm: "http://Example.COM:8080")?.authority
                == Authority(host: "example.com", port: 8080))
    }

    @Test func handlesIPv6AndUserInfo() {
        #expect(ProxyTarget(absoluteForm: "http://[::1]:9000/x")?.authority == Authority(host: "::1", port: 9000))
        #expect(
            ProxyTarget(absoluteForm: "http://user:secret@host.test/x")?.authority
                == Authority(host: "host.test", port: 80))
    }

    @Test(arguments: [
        "https://example.com/", "/relative", "http://example.com:99999/", "http:///path", "ftp://example.com/",
    ])
    func rejectsWhatItCannotForward(_ uri: String) {
        #expect(ProxyTarget(absoluteForm: uri) == nil)
    }

    @Test func readsAuthorities() {
        #expect(Authority("api.weatherly.dev:443", defaultPort: 443) == Authority(host: "api.weatherly.dev", port: 443))
        #expect(Authority("[::1]", defaultPort: 443) == Authority(host: "::1", port: 443))
        #expect(Authority("host:", defaultPort: 443) == nil)
        #expect(Authority("", defaultPort: 443) == nil)
    }
}
