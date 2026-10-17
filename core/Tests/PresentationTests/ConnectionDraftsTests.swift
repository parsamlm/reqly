import Foundation
import Presentation
import ReqlyModel
import Testing

@Suite struct ConnectionDraftsTests {
    @Test func readsAListOfHosts() {
        let list = HostList("intranet.example.com, *.Corp.example.com\nprinter.local  not/a/host,,")
        #expect(list.patterns.map(\.rawValue) == ["intranet.example.com", "*.corp.example.com", "printer.local"])
        #expect(list.invalid == ["not/a/host"])
        #expect(list.problem == "“not/a/host” isn't a host name or a pattern such as *.example.com.")
        #expect(HostList("").patterns.isEmpty && HostList(" , ").problem == nil)
        #expect(HostList.text(list.patterns) == "intranet.example.com, *.corp.example.com, printer.local")
    }

    @Test func checksTheUpstreamProxyWhileItsOn() {
        var draft = UpstreamProxyDraft()
        draft.port = "x"
        #expect(draft.problem(proxyPort: 9090) == nil)
        draft.isOn = true
        #expect(draft.problem(proxyPort: 9090) == "Enter the proxy's server.")
        draft.host = "http://proxy.example.com"
        #expect(draft.problem(proxyPort: 9090) == "The server is a host name or an address, without http:// or a path.")
        draft.host = " proxy.example.com "
        #expect(draft.problem(proxyPort: 9090) == "The port is a number from 1 to 65535.")
        draft.port = "70000"
        #expect(draft.problem(proxyPort: 9090) == "The port is a number from 1 to 65535.")
        draft.port = "8080"
        draft.bypass = "intranet.example.com, *."
        #expect(draft.problem(proxyPort: 9090) == "“*.” isn't a host name or a pattern such as *.example.com.")
        draft.bypass = "intranet.example.com"
        #expect(draft.problem(proxyPort: 9090) == nil)
        var loop = draft
        loop.host = "127.0.0.1"
        loop.port = "9090"
        #expect(loop.problem(proxyPort: 9090) == "That's Reqly's own address. Enter the other proxy's.")
        #expect(loop.problem(proxyPort: 9191) == nil)
    }

    @Test func turnsTheDraftIntoAProxyAndBack() throws {
        var draft = UpstreamProxyDraft()
        draft.isOn = true
        draft.host = " Proxy.Example.com "
        draft.port = " 8080 "
        draft.password = "hunter2"
        draft.bypass = "intranet.example.com bad/entry"
        // A password without a user name isn't kept.
        var proxy = try #require(draft.proxy)
        #expect(proxy.host == "proxy.example.com" && proxy.port == 8080)
        #expect(proxy.username == nil && proxy.password == nil)
        #expect(proxy.bypass.map(\.rawValue) == ["intranet.example.com"])
        draft.username = " parsa "
        proxy = try #require(draft.proxy)
        #expect(proxy.username == "parsa" && proxy.password == "hunter2")
        let shown = UpstreamProxyDraft(proxy, isOn: true)
        #expect(shown.host == "proxy.example.com" && shown.port == "8080" && shown.bypass == "intranet.example.com")
        #expect(shown.username == "parsa" && shown.password == "hunter2" && shown.isOn)
        draft.port = ""
        #expect(draft.proxy == nil)
    }

    @Test func checksAReverseProxyAsYouEditIt() {
        let other = ReverseProxy(localPort: 8080, serverURL: "https://api.weatherly.dev")
        var proxy = ReverseProxy(localPort: 0, serverURL: "")
        let proxies = [other]
        #expect(proxy.problem(port: "abc", proxyPort: 9090, among: proxies) == "The port is a number from 1 to 65535.")
        #expect(
            proxy.problem(port: "9090", proxyPort: 9090, among: proxies) == "Port 9090 is the one Reqly's proxy uses.")
        #expect(proxy.problem(port: "8080", proxyPort: 9090, among: proxies) == "Another reverse proxy uses port 8080.")
        #expect(
            proxy.problem(port: " 8081 ", proxyPort: 9090, among: proxies) == "Enter the server that requests go to.")
        proxy.serverURL = "ftp://files.weatherly.dev"
        #expect(
            proxy.problem(port: "8081", proxyPort: 9090, among: proxies)
                == "The server is an address such as https://api.example.com.")
        proxy.serverURL = "staging.weatherly.dev"
        #expect(proxy.problem(port: "8081", proxyPort: 9090, among: proxies) == nil)
        // A proxy's own port isn't another's.
        #expect(other.problem(port: "8080", proxyPort: 9090, among: proxies) == nil)
        #expect(ReverseProxy.suggestedPort(among: proxies, proxyPort: 8081) == 8082)
        #expect(ReverseProxy.suggestedPort(among: [], proxyPort: 9090) == 8080)
    }
}
