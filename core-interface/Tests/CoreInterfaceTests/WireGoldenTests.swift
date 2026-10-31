import DeviceBridge
import Foundation
import ProxyEngine
import ReqlyModel
import Synchronization
import Testing
import TrafficStore

@testable import CoreInterface

/// The exact JSON a session puts on the wire: each call's reply and the events that follow it,
/// written down in Tests/WireGoldens from the code as it was, so a change to how SessionHost works
/// inside can show that the Windows app sees nothing different. Each scenario drives a session
/// through `reply(to:)`, as the app does, and compares the whole run with its golden file, line for
/// line, keys in their order and numbers as they're written.
///
/// When the wire is meant to change, record the goldens again with `REQLY_RECORD_WIRE_GOLDENS=1`
/// in the environment, and read the difference before keeping it.
@Suite(.serialized) struct WireGoldenTests {
    /// A saved session: the list, the details and bodies, rules, Protobuf files, saving and export.
    @Test func savedSession() async throws {
        let run = WireRun("SavedSession")
        defer { run.removeFolder() }
        let file = try await WireTraffic.saveSession(in: run.folder)
        let host = try await run.open(
            OpenOptions(sessionsFolder: run.path("Sessions"), file: file.path), protobuf: ProtobufLibrary(),
            line: "open a saved session of 8 exchanges", kept: .allButOpeningSidebar,
            until: { WireRun.kind($0).name == "rows" })
        let sidebar = try #require(run.lastEvents.last { WireRun.kind($0).name == "sidebar" })
        let keys = try Self.sidebarKeys(sidebar)

        // What's wrong with a request, before any call runs.
        await run.call("not json")
        await run.call(#"{"port":1}"#)
        await run.call(#"{"call":"fly"}"#)
        await run.call(#"{"call":"startCapturing"}"#)
        await run.call(#"{"call":"presentBody","id":1,"part":"trailer"}"#)
        await run.call(#"{"call":"removeDecryptedHosts","patterns":["not a host"]}"#)
        await run.call(#"{"call":"annotate","id":1,"color":"teal"}"#)

        // The list and what each exchange holds.
        await run.call(#"{"call":"version"}"#)
        await run.call(#"{"call":"rowIDs"}"#)
        await run.call(#"{"call":"rows","ids":[1,2,3,4,5,6,7,8,99]}"#)
        await run.call(#"{"call":"trafficSummary"}"#)
        for id in 1...8 {
            await run.call(#"{"call":"details","id":\#(id)}"#)
        }
        await run.call(#"{"call":"details","id":99}"#)
        for (id, part) in [
            (1, "response"), (2, "request"), (2, "response"), (3, "response"), (4, "response"), (5, "response"),
            (6, "response"), (7, "response"), (8, "request"),
        ] {
            await run.call(#"{"call":"presentBody","id":\#(id),"part":"\#(part)"}"#)
        }
        await run.call(#"{"call":"bodyNode","id":1,"part":"response","node":3}"#)
        await run.call(#"{"call":"bodyNode","id":1,"part":"response","node":999}"#)
        await run.call(#"{"call":"raw","id":1}"#)
        await run.call(#"{"call":"raw","id":1,"showsSecrets":true}"#)
        await run.call(#"{"call":"raw","id":2}"#)
        await run.call(#"{"call":"raw","id":4}"#)
        await run.call(#"{"call":"raw","id":6}"#)
        await run.call(#"{"call":"messages","id":4}"#)
        await run.call(#"{"call":"messages","id":4,"from":2}"#)
        await run.call(#"{"call":"messages","id":1}"#)
        for number in [0, 2, 3, 9] {
            await run.call(#"{"call":"presentMessage","id":4,"number":\#(number)}"#)
        }

        // Copying, resending and writing requests. Nothing here reaches the network: the requests
        // it would send are ones that can't be.
        for id in [1, 2, 6, 99] {
            await run.call(#"{"call":"draft","id":\#(id)}"#)
        }
        await run.call(#"{"call":"curl","id":1}"#)
        await run.call(#"{"call":"curl","id":2}"#)
        for id in [1, 3, 7, 8] {
            await run.call(#"{"call":"copyableBody","id":\#(id)}"#)
        }
        await run.call(#"{"call":"send","request":{"method":"GET","url":"ftp://example.com","headers":[]}}"#)
        await run.call(#"{"call":"resend","id":6}"#)
        await run.call(#"{"call":"resend","id":99}"#)
        await run.call(#"{"call":"decide","id":1}"#)
        await run.call(#"{"call":"continueAllPaused"}"#)

        // Scripts, presets and small helpers.
        await run.call(["call": "checkScript", "code": "function onRequest(request) { return request }"])
        await run.call(["call": "checkScript", "code": "function onRequest( {"])
        await run.call(["call": "highlightScript", "code": "// é\nfunction onRequest(r) { return \"ok\" } // 42"])
        let tried = "function onRequest(request) {\n  console.log(request.method, request.url)\n  return request\n}"
        await run.call(["call": "tryScript", "code": tried, "id": 1])
        await run.call(["call": "tryScript", "code": "function onRequest(request) { throw new Error('no') }", "id": 2])
        await run.call(#"{"call":"scriptExamples"}"#)
        await run.call(#"{"call":"networkPresets"}"#)
        await run.call(#"{"call":"qrCode","text":"http://192.168.1.125:9090"}"#)
        await run.call(["call": "qrCode", "text": String(repeating: "weather ", count: 380)])
        await run.call(#"{"call":"checkHosts","text":"api.bank.dev, *.bank.dev"}"#)
        await run.call(#"{"call":"checkHosts","text":"api.bank.dev, bad/host"}"#)
        await run.call(#"{"call":"https"}"#)

        // Searching, filtering and narrowing the list, then showing it all again. "Lisbon" is only
        // in a body, which the store finds a moment after the list.
        await run.call(#"{"call":"setSearch","text":"status"}"#)
        await run.call(#"{"call":"setSearch","text":"Lisbon"}"#, until: Self.inserts)
        await run.call(#"{"call":"setSearch","text":""}"#)
        await run.call(#"{"call":"setFilter","filter":{"statuses":["clientError","failed"]}}"#)
        await run.call(#"{"call":"setFilter","filter":{"contents":["json"],"host":"api.weatherly.dev"}}"#)
        await run.call(#"{"call":"setFilter","filter":{"method":"POST","device":""}}"#)
        await run.call(#"{"call":"setFilter","filter":{}}"#)
        await run.call(#"{"call":"setFilter","filter":{"statuses":["teapot"]}}"#)
        for key in [keys.app, keys.host, keys.device, "pinned", "all", "host-nowhere"] {
            await run.call(["call": "setScope", "key": key])
        }

        // Marking exchanges. The store saves each change, and the list shows it again once it has.
        await run.call(#"{"call":"annotate","id":2,"isPinned":true,"color":"red","comment":"  Slow on 3G  "}"#)
        await run.call(#"{"call":"annotate","id":2,"color":null}"#)
        await run.call(#"{"call":"annotate","id":2,"comment":" "}"#)
        await run.call(#"{"call":"annotate","id":99,"isPinned":true}"#)
        await run.call(#"{"call":"rows","ids":[2]}"#)

        try await Self.editRules(run)
        try await Self.readProtobuf(run)

        // Naming a device's traffic.
        await run.call(["call": "openDevices", "path": run.path("Devices.json")])
        await run.call(#"{"call":"renameDevice","device":"mac:aa:bb:cc:dd:ee:ff","name":"Parsa's phone"}"#)
        await run.call(#"{"call":"rows","ids":[5]}"#)
        await run.call(#"{"call":"renameDevice","device":"mac:aa:bb:cc:dd:ee:ff","name":" "}"#)

        // Saving and exporting, then clearing, which keeps the pinned exchange.
        await run.call(["call": "saveSession", "path": run.path("Saved.reqly"), "hidesSecrets": true])
        await run.call(["call": "exportHAR", "path": run.path("All.har"), "version": "0.1"])
        await run.call([
            "call": "exportHAR", "path": run.path("Two.har"), "ids": [2, 6], "includesResponseBodies": false,
            "hidesSecrets": false,
        ])
        await run.call(#"{"call":"clear"}"#)
        await run.call(#"{"call":"unpinAll"}"#)
        await run.call(#"{"call":"rowIDs"}"#)
        await run.call(#"{"call":"trafficSummary"}"#)
        await host.close()
        try run.finish()
    }

    /// The Rules window's calls, on a rules file that isn't there yet.
    static func editRules(_ run: WireRun) async throws {
        await run.call(["call": "openRules", "path": run.path("Settings/Rules.json")])
        await run.call(#"{"call":"rules"}"#)
        var draft = try result(await run.call(#"{"call":"newRuleDraft","kind":"mapRemote","id":1}"#))
        draft["destination"] = "staging"
        await run.call(["call": "checkRuleDraft", "draft": draft])
        await run.call(["call": "saveRuleDraft", "draft": draft])
        draft["destination"] = "https://staging.weatherly.dev"
        let saved = try result(await run.call(["call": "saveRuleDraft", "draft": draft]))
        let mapRemote = try #require((saved["rules"] as? [[String: Any]])?.first?["id"] as? String)
        var edit = try result(await run.call(["call": "ruleDraft", "rule": mapRemote]))
        edit["name"] = "Staging"
        await run.call(["call": "saveRuleDraft", "draft": edit])

        var ids: [String] = []
        for (name, status) in [("Ads", 403), ("Trackers", 451)] {
            var block = try result(await run.call(#"{"call":"newRuleDraft","kind":"block"}"#))
            block["name"] = name
            block["blockStatus"] = status
            let rules = try result(await run.call(["call": "saveRuleDraft", "draft": block]))
            ids = (rules["rules"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        }
        var breakpoint = try result(await run.call(#"{"call":"newRuleDraft","kind":"breakpoint"}"#))
        breakpoint["phase"] = "response"
        await run.call(["call": "saveRuleDraft", "draft": breakpoint])
        await run.call(["call": "moveRule", "rule": ids[2], "to": 0])
        await run.call(["call": "duplicateRule", "rule": ids[1]])
        await run.call(["call": "setRuleOn", "rule": ids[1], "isOn": false])
        await run.call(#"{"call":"setRuleKindOn","kind":"breakpoint","isOn":false}"#)
        await run.call(["call": "removeRules", "ruleIDs": [ids[0]]])

        let presets = try results(await run.call(#"{"call":"networkPresets"}"#))
        let lte = try #require(presets.first { $0["name"] as? String == "LTE" })
        await run.call(["call": "setNetwork", "network": ["profile": lte, "hosts": ["*.weatherly.dev"]]])
        await run.call(#"{"call":"setRuleKindOn","kind":"slowNetwork","isOn":true}"#)

        let script = try result(await run.call(#"{"call":"newRuleDraft","kind":"script"}"#))
        await run.call(["call": "checkRuleDraft", "draft": script])
        await run.call(#"{"call":"newRuleDraft","kind":"block","id":99}"#)
        await run.call(#"{"call":"newRuleDraft","kind":"slowNetwork"}"#)
        await run.call(#"{"call":"ruleDraft","rule":"00000000-0000-0000-0000-000000000000"}"#)

        // A whole rule set, as the app sends the rules file's.
        let rules = RuleSet(
            rules: [
                Rule(
                    id: UUID(uuidString: "0B10C4ED-0000-4000-8000-000000000001")!, name: "No ads",
                    match: RequestMatch(host: "ads.weatherly.dev"), action: .block(.status(403)))
            ], kindsOn: [.block])
        await run.call(#"{"call":"setRules","rules":\#(WireRun.encoded(rules))}"#)
        await run.call(#"{"call":"rules"}"#)
    }

    /// The `.proto` files' calls, and the bodies they change.
    static func readProtobuf(_ run: WireRun) async throws {
        let protos = run.folder.appending(path: "protos")
        try FileManager.default.createDirectory(
            at: protos.appending(path: "weather/v1"), withIntermediateDirectories: true)
        try Data(
            """
            syntax = "proto3";
            package weather.v1;
            message Forecast { string city = 1; int32 days = 2; }
            message Other { bool ok = 1; }
            """.utf8
        ).write(to: protos.appending(path: "weather/v1/forecast.proto"))
        try Data("syntax = \"proto3\";\nmessage Broken {\n".utf8).write(to: protos.appending(path: "broken.proto"))

        await run.call(["call": "openProtobuf", "path": run.path("Protobuf.json")])
        await run.call(#"{"call":"presentBody","id":3,"part":"response"}"#)
        let added = try result(await run.call(["call": "addProtobufSources", "paths": [run.path("protos")]]))
        let listed = try #require((added["sources"] as? [[String: Any]])?.first?["path"] as? String)
        await run.call(["call": "addProtobufSources", "paths": [run.path("protos")]])
        await run.call(#"{"call":"protobuf"}"#)
        await run.call(#"{"call":"presentBody","id":3,"part":"response"}"#)
        await run.call(#"{"call":"chooseMessageType","id":3,"part":"response","type":"weather.v1.Forecast"}"#)
        await run.call(#"{"call":"presentBody","id":3,"part":"response"}"#)
        await run.call(#"{"call":"reloadProtobuf"}"#)
        await run.call(#"{"call":"chooseMessageType","id":3,"part":"response"}"#)
        await run.call(["call": "removeProtobufSource", "path": listed])
        await run.call(#"{"call":"presentBody","id":3,"part":"response"}"#)
    }

    /// A live session that doesn't capture: HTTPS on a stand-in store, connection settings with
    /// plain secrets, devices that ask as if they had connected, and emulators without adb.
    @Test func liveSession() async throws {
        let run = WireRun("LiveSession")
        defer { run.removeFolder() }
        let root = run.folder.appending(path: "Root.plist")
        let host = try await run.open(
            OpenOptions(sessionsFolder: run.path("Sessions"), findsApps: false, rootStandIn: root.path),
            line: "open a live session")

        // Port 0 picks a free port; only this computer can connect.
        await run.call(#"{"call":"startCapturing","port":0}"#, masking: ["port"])
        await run.call(#"{"call":"stopCapturing"}"#)

        // HTTPS: set up with a root made once for these tests, so its certificate is the same each run.
        await run.call(#"{"call":"https"}"#)
        try FixedRoot.write(to: root)
        await run.call(#"{"call":"setUpHTTPS"}"#)
        await run.call(#"{"call":"https"}"#)
        await run.call(
            #"{"call":"setDecryptedHosts","hosts":{"entries":[{"pattern":"*.weatherly.dev","isOn":true},{"pattern":"not a host","isOn":true}],"includesEveryHost":false}}"#
        )
        await run.call(#"{"call":"addDecryptedHost","text":" *.Example.com "}"#)
        await run.call(#"{"call":"addDecryptedHost","text":"not a host"}"#)
        await run.call(#"{"call":"decryptHost","host":"api.bank.dev"}"#)
        await run.call(#"{"call":"stopDecryptingHost","host":"api.weatherly.dev"}"#)
        await run.call(#"{"call":"setHostDecrypted","pattern":"*.weatherly.dev","isOn":false}"#)
        await run.call(#"{"call":"removeDecryptedHosts","patterns":["*.example.com"]}"#)
        await run.call(#"{"call":"setDecryptsEveryHost","isOn":true}"#)
        await run.call(#"{"call":"decryptsHost","host":"example.org"}"#)
        await run.call(#"{"call":"decryptsHost","host":"api.weatherly.dev"}"#)
        await run.call(#"{"call":"setDecryptsEveryHost","isOn":false}"#)
        await run.call(#"{"call":"removeHTTPS"}"#)
        await run.call(#"{"call":"removeHTTPS"}"#)

        try await Self.editConnections(run)

        // Devices, while nothing listens on the network: the session doesn't capture.
        await run.call(["call": "openDevices", "path": run.path("Devices.json")])
        await run.call(#"{"call":"devices"}"#)
        await run.call(#"{"call":"setAllowsNetworkDevices","isOn":true}"#)
        var asking: Task<Bool, Never>?
        await run.stimulus("admit 192.168.1.20", until: { WireRun.kind($0).name == "deviceWaiting" }) {
            asking = Task { await host.admit(ClientAddress(ip: "192.168.1.20", port: 50_000)) }
        }
        await run.call(#"{"call":"devices"}"#)
        await run.call(#"{"call":"decideDevice","device":"ip:192.168.1.20","allow":true,"name":" Phone "}"#)
        #expect(await asking?.value == true)
        await run.call(#"{"call":"renameDevice","device":"ip:192.168.1.20","name":"Parsa's phone"}"#)
        var refused: Task<Bool, Never>?
        await run.stimulus("admit 192.168.1.21", until: { WireRun.kind($0).name == "deviceWaiting" }) {
            refused = Task { await host.admit(ClientAddress(ip: "192.168.1.21", port: 50_001)) }
        }
        await run.call(#"{"call":"setAllowsNetworkDevices","isOn":false}"#)
        #expect(await refused?.value == false)
        await run.call(#"{"call":"forgetDevice","device":"ip:192.168.1.20"}"#)
        await run.call(#"{"call":"renameDevice","device":"ip:192.168.1.20","name":" "}"#)
        await run.call(#"{"call":"decideDevice","device":"ip:10.0.0.9","allow":false}"#)

        // Emulators, as on a computer without Android's tools.
        await run.withoutAdb {
            await run.call(#"{"call":"emulators","port":9090}"#)
            await run.call(#"{"call":"setEmulatorUsesReqly","serial":"emulator-5554","isOn":true,"port":9090}"#)
            await run.call(#"{"call":"copyCertificateToEmulator","serial":"emulator-5554","certificate":"AAAA"}"#)
        }
        await host.close()
        try run.finish()
    }

    /// The connection settings' calls, on their own files with plain secrets.
    static func editConnections(_ run: WireRun) async throws {
        await run.call([
            "call": "openConnections", "path": run.path("Connections.json"), "secretsPath": run.path("Secrets.json"),
            "protectsSecrets": false,
        ])
        await run.call(#"{"call":"connections"}"#)
        var proxy: [String: Any] = [
            "isOn": true, "host": "", "port": "8080", "username": "parsa", "password": "hunter2",
            "bypass": "intranet.example.com", "bypassesLocalAddresses": true,
        ]
        await run.call(["call": "checkUpstreamProxy", "proxy": proxy, "proxyPort": 9090])
        await run.call(["call": "setUpstreamProxy", "proxy": proxy, "proxyPort": 9090])
        proxy["host"] = "Proxy.Example.com"
        await run.call(["call": "checkUpstreamProxy", "proxy": proxy, "proxyPort": 9090])
        await run.call(["call": "setUpstreamProxy", "proxy": proxy, "proxyPort": 9090])
        proxy["isOn"] = false
        proxy["username"] = ""
        await run.call(["call": "setUpstreamProxy", "proxy": proxy, "proxyPort": 9090])

        var reverse = try result(await run.call(#"{"call":"newReverseProxy","proxyPort":8080}"#))
        await run.call(["call": "checkReverseProxy", "proxy": reverse, "proxyPort": 8080])
        reverse["serverURL"] = "staging.weatherly.dev"
        await run.call(["call": "checkReverseProxy", "proxy": reverse, "proxyPort": 8080])
        await run.call(["call": "saveReverseProxy", "proxy": reverse, "proxyPort": 8080])
        var second = try result(await run.call(#"{"call":"newReverseProxy","proxyPort":8080}"#))
        second["port"] = "8081"
        second["serverURL"] = "https://api.weatherly.dev"
        await run.call(["call": "saveReverseProxy", "proxy": second, "proxyPort": 8080])
        let id = try #require(reverse["id"] as? String)
        await run.call(["call": "setReverseProxyOn", "reverseProxy": id, "isOn": false])
        await run.call(#"{"call":"connections"}"#)
        await run.call(["call": "removeReverseProxy", "reverseProxy": id])

        let pem = run.folder.appending(path: "client.pem")
        try Data((ConnectionsTests.certificate + ConnectionsTests.key).utf8).write(to: pem)
        await run.call(["call": "addClientCertificate", "files": [run.path("nowhere.p12")], "hosts": "api.bank.dev"])
        await run.call(["call": "addClientCertificate", "files": [run.path("client.pem")], "hosts": " "])
        let added = try result(
            await run.call([
                "call": "addClientCertificate", "files": [run.path("client.pem")], "password": "",
                "hosts": "api.bank.dev, *.bank.dev",
            ]))
        let certificate = try #require((added["clientCertificates"] as? [[String: Any]])?.first?["id"] as? String)
        await run.call(["call": "setClientCertificateHosts", "certificate": certificate, "hosts": "api.bank.dev"])
        await run.call(["call": "setClientCertificateHosts", "certificate": certificate, "hosts": "bad/host"])
        await run.call(["call": "setClientCertificateOn", "certificate": certificate, "isOn": false])
        await run.call(["call": "removeClientCertificate", "certificate": certificate])
    }

    /// Requests Reqly sends itself, held at a breakpoint and let go. They're for `.invalid`, which
    /// never resolves, so nothing leaves the computer. How many times their rows change, and when,
    /// depends on how fast each one fails, so only the `paused` and `resumed` events are kept.
    @Test func liveTraffic() async throws {
        let run = WireRun("LiveTraffic")
        defer { run.removeFolder() }
        let host = try await run.open(
            OpenOptions(sessionsFolder: run.path("Sessions"), findsApps: false), line: "open a live session")
        let kept = WireRun.Kept.only(["paused", "resumed"])
        let paused = { (event: Data) in WireRun.kind(event).name == "paused" }
        let rules = RuleSet(
            rules: [
                Rule(
                    id: UUID(uuidString: "B4EA4901-0000-4000-8000-000000000001")!, name: "Hold the weather",
                    match: RequestMatch(host: "weather.invalid"), action: .breakpoint(.request))
            ], kindsOn: [.breakpoint])
        await run.call(#"{"call":"setRules","rules":\#(WireRun.encoded(rules))}"#, kept: kept)

        let forecast =
            #"{"call":"send","request":{"method":"GET","url":"https://weather.invalid/v2/forecast","headers":[{"name":"Accept","value":"application/json"}]}}"#
        await run.call(forecast, kept: kept, until: paused)
        await run.call(#"{"call":"decide","id":1,"edit":{"url":"ftp://weather.invalid/"}}"#, kept: kept)
        await run.call(
            #"{"call":"decide","id":1,"edit":{"url":"https://weather.invalid/v2/edited","headers":[{"name":"X-Edited","value":"1","isSecret":false}],"body":"{}"}}"#,
            kept: kept)
        await run.waitForExchange(1)
        await run.call(#"{"call":"resend","id":1}"#, kept: kept, until: paused)
        await run.call(#"{"call":"continueAllPaused"}"#, kept: kept)
        let ftp = #"{"call":"send","request":{"method":"GET","url":"ftp://example.com","headers":[]}}"#
        await run.call(ftp, kept: kept)
        await run.call(
            #"{"call":"send","request":{"method":"POST","url":"report.invalid/v2/report","headers":[{"name":"X-Kept","value":"1"},{"name":"X-Off","value":"2","isOn":false}],"body":"sunny"}}"#,
            kept: kept)
        await run.call(forecast, kept: kept, until: paused)
        await run.call(#"{"call":"decide","id":4}"#, kept: kept)
        await run.call(forecast, kept: kept, until: paused)
        await run.call(#"{"call":"clear"}"#, kept: kept)
        await run.call(#"{"call":"decide","id":5}"#, kept: kept)
        await host.close()
        try run.finish()
    }

    /// Every call the app can make has a reply in the goldens, so none goes unchecked.
    @Test func everyCallIsInAGolden() throws {
        var called: Set<String> = []
        for name in ["SavedSession", "LiveSession", "LiveTraffic"] {
            let text = try String(contentsOf: WireRun.goldens.appending(path: "\(name).txt"), encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("call {") {
                let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                if let call = object?["call"] as? String {
                    called.insert(call)
                }
            }
        }
        let missing = Set(Self.calls).subtracting(called)
        #expect(missing.isEmpty, "Not in any golden: \(missing.sorted())")
        let unread = Set(Self.firstCalls).subtracting(Self.calls)
        #expect(unread.isEmpty, "Not read from Messages.swift: \(unread.sorted())")
    }

    /// Every call in Messages.swift, by the name the app sends, as `Call(json:)` reads it, so a
    /// call added there must be added to a golden too.
    static let calls: [String] = {
        let messages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/CoreInterface/Messages.swift")
        guard let text = try? String(contentsOf: messages, encoding: .utf8),
            let start = text.firstRange(of: "switch name {"),
            let end = text[start.upperBound...].firstRange(of: "throw Problem(.unknownCall")
        else { return [] }
        return text[start.upperBound..<end.lowerBound].matches(of: #/case "(\w+)":/#).map { String($0.output.1) }
    }()

    /// The calls as they were when the goldens were first recorded: `calls` must find them all,
    /// so a change to how Messages.swift is written can't empty it unnoticed.
    static let firstCalls = [
        "version", "startCapturing", "stopCapturing", "rowIDs", "rows", "trafficSummary", "setSearch", "details",
        "presentBody", "raw", "bodyNode", "messages", "presentMessage", "https", "setUpHTTPS", "removeHTTPS",
        "setDecryptedHosts", "decryptHost", "stopDecryptingHost", "addDecryptedHost", "removeDecryptedHosts",
        "setHostDecrypted", "setDecryptsEveryHost", "decryptsHost", "setScope", "setFilter", "annotate", "unpinAll",
        "clear", "saveSession", "exportHAR", "setRules", "openRules", "rules", "setRuleKindOn", "setRuleOn",
        "removeRules", "moveRule", "duplicateRule", "newRuleDraft", "ruleDraft", "checkRuleDraft", "saveRuleDraft",
        "setNetwork", "networkPresets", "scriptExamples", "openConnections", "connections", "checkUpstreamProxy",
        "setUpstreamProxy", "newReverseProxy", "checkReverseProxy", "saveReverseProxy", "removeReverseProxy",
        "setReverseProxyOn", "checkHosts", "addClientCertificate", "setClientCertificateHosts",
        "setClientCertificateOn", "removeClientCertificate", "openProtobuf", "protobuf", "addProtobufSources",
        "removeProtobufSource", "reloadProtobuf", "openDevices", "devices", "setAllowsNetworkDevices", "decideDevice",
        "forgetDevice", "renameDevice", "qrCode", "emulators", "setEmulatorUsesReqly", "copyCertificateToEmulator",
        "chooseMessageType", "decide", "continueAllPaused", "checkScript", "highlightScript", "tryScript", "send",
        "resend", "draft", "curl", "copyableBody",
    ]

    /// Whether a rows event put rows in.
    static func inserts(_ event: Data) -> Bool {
        let object = (try? JSONSerialization.jsonObject(with: event)) as? [String: Any]
        return (object?["steps"] as? [[String: Any]])?.contains { $0["inserted"] != nil } == true
    }

    /// The keys of the sidebar's first app, its last host and its first device, as `setScope` takes them.
    static func sidebarKeys(_ event: Data) throws -> (app: String, host: String, device: String) {
        let sidebar = try #require(try JSONSerialization.jsonObject(with: event) as? [String: Any])
        let app = try #require((sidebar["apps"] as? [[String: Any]])?.first?["key"] as? String)
        let host = try #require((sidebar["hosts"] as? [[String: Any]])?.last?["key"] as? String)
        let device = try #require((sidebar["devices"] as? [[String: Any]])?.last?["key"] as? String)
        return (app, host, device)
    }
}

/// Every event a session sent, in order, as the app got them.
final class WireLog: Sendable {
    private let events = Mutex<[Data]>([])

    func record(_ json: Data) {
        events.withLock { $0.append(json) }
    }

    var all: [Data] {
        events.withLock { $0 }
    }
}

/// One scenario's run: the session's folder, the lines written down so far, and the golden file
/// they're compared with.
///
/// Each step is a line for the call, as sent, one for its reply, and one for each event that came
/// after it, before the next call. Recording waits for the session to go quiet after each step;
/// comparing waits for as many events as the golden file has, then a moment more for any extra.
///
/// Only what differs from run to run is replaced, before comparing:
/// - the test's temporary folder, wherever the system keeps it, by `$FOLDER`, with `/` between the
///   names after it;
/// - what Swift says about JSON it couldn't decode, after "is missing something:", by
///   `$decodingError`, since its words are the toolchain's, not Reqly's;
/// - UUIDs, which rules, drafts, reverse proxies and certificates get anew, by `$UUID1`, `$UUID2`…
///   in the order they first appear;
/// - the numbers of the keys a step names, such as the free port capturing picked, by `$` and the key.
final class WireRun {
    /// Which of a step's events go in the golden file.
    enum Kept {
        case all
        /// Only these kinds of events. The others depend on how fast live traffic goes.
        case only(Set<String>)
        /// All but a sidebar with no traffic in it, which a saved session sends as it opens, before
        /// or after its traffic shows, depending on which gets there first.
        case allButOpeningSidebar
    }

    static let goldens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "WireGoldens")
    static let isRecording = ProcessInfo.processInfo.environment["REQLY_RECORD_WIRE_GOLDENS"] == "1"

    let name: String
    let folder: URL
    let log = WireLog()
    /// The events the latest step kept, as they came.
    private(set) var lastEvents: [Data] = []
    private var host: SessionHost?
    private var lines: [String] = []
    private var golden: String?
    /// The golden file's steps, each as its lines.
    private var goldenSteps: [[String]] = []
    private var steps = 0
    private var consumed = 0
    private var uuids: [String: String] = [:]

    init(_ name: String) {
        self.name = name
        folder = URL.temporaryDirectory.appending(path: "ReqlyWireGolden-\(UUID().uuidString)")
        lines = [
            "# The JSON SessionHost puts on the wire, as WireGoldenTests.swift records it. Each step is",
            "# its call, its reply, and the events after it. Set REQLY_RECORD_WIRE_GOLDENS=1 to record again.",
        ]
        if !Self.isRecording,
            let text = try? String(contentsOf: Self.goldens.appending(path: "\(name).txt"), encoding: .utf8)
        {
            golden = text.replacingOccurrences(of: "\r", with: "")
            for line in golden?.split(separator: "\n") ?? [] {
                if Self.startsAStep(line) {
                    goldenSteps.append([String(line)])
                } else if !goldenSteps.isEmpty {
                    goldenSteps[goldenSteps.count - 1].append(String(line))
                }
            }
        }
    }

    static func startsAStep(_ line: some StringProtocol) -> Bool {
        ["call ", "open ", "admit "].contains(where: line.hasPrefix)
    }

    func path(_ name: String) -> String {
        folder.appending(path: name).path(percentEncoded: false)
    }

    /// The ways the run's folder is written, the longest first, so only the folder itself becomes
    /// `$FOLDER`, and anything written before it, such as `file://`, shows as a difference: as a
    /// path, as the system writes it, and through `/private`, where macOS's temporary folder
    /// really is. On Windows, also with `/` or `\` between the names, and each `\` escaped as
    /// JSON escapes it.
    private var folderSpellings: [String] {
        let path = folder.path(percentEncoded: false)
        let native = folder.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? path
        var spellings: Set<String> = [path, native, "/private" + path]
        #if os(Windows)
            for spelling in [path, native] {
                let backslashed = spelling.replacingOccurrences(of: "/", with: "\\")
                spellings.insert(spelling.replacingOccurrences(of: "\\", with: "/"))
                spellings.insert(backslashed)
                spellings.insert(backslashed.replacingOccurrences(of: "\\", with: "\\\\"))
            }
        #endif
        return spellings.sorted { $0.count > $1.count }
    }

    func removeFolder() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Opens the session, and writes down the events it sent as it opened.
    func open(
        _ options: OpenOptions, protobuf: ProtobufLibrary = ProtobufLibrary(), line: String, kept: Kept = .all,
        until: ((Data) -> Bool)? = nil
    ) async throws -> SessionHost {
        let log = self.log
        let host = try await SessionHost.open(options, protobuf: protobuf, send: { log.record($0) })
        self.host = host
        lines += ["", line]
        await settle(kept, until: until)
        return host
    }

    /// Sends a call and writes down its reply and the events after it. Returns the reply as it came.
    @discardableResult
    func call(_ json: String, kept: Kept = .all, masking keys: [String] = [], until: ((Data) -> Bool)? = nil)
        async -> Data
    {
        guard let host else { return Data() }
        let reply = await host.reply(to: Data(json.utf8))
        lines += ["", "call " + normalized(json), "reply " + normalized(String(decoding: reply, as: UTF8.self), keys)]
        await settle(kept, until: until)
        return reply
    }

    /// A call written as JSON from its fields, keys in order.
    @discardableResult
    func call(_ fields: [String: Any], kept: Kept = .all, until: ((Data) -> Bool)? = nil) async -> Data {
        await call(Self.json(fields), kept: kept, until: until)
    }

    /// Something that isn't a call but makes the session send events, such as a device asking to
    /// connect, and the events it sent.
    func stimulus(_ line: String, kept: Kept = .all, until: ((Data) -> Bool)? = nil, _ work: () async -> Void) async {
        await work()
        lines += ["", line]
        await settle(kept, until: until)
    }

    /// Waits up to five seconds for the store to have an exchange, which the session has no other
    /// way to find until then, without writing anything down.
    func waitForExchange(_ id: Int) async {
        for _ in 0..<500 {
            let reply = await host?.reply(to: Data(#"{"call":"details","id":\#(id)}"#.utf8)) ?? Data()
            if !String(decoding: reply, as: UTF8.self).hasPrefix(#"{"problem""#) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Hides adb from the session for the length of `work`, so the emulator calls give the replies
    /// they give on a computer without Android's tools, and adb never runs, wherever it's
    /// installed.
    func withoutAdb(_ work: () async -> Void) async {
        await host?.findAdb(with: { nil })
        await work()
        await host?.findAdb(with: { AndroidDebugBridge.find() })
    }

    /// Waits for a step's events, then writes down the ones it keeps.
    private func settle(_ kept: Kept, until: ((Data) -> Bool)?) async {
        let clock = ContinuousClock()
        await host?.capture.flush()
        if Self.isRecording {
            let deadline = clock.now + .seconds(10)
            var count = log.all.count
            var quietSince = clock.now
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
                let all = log.all
                if all.count != count {
                    count = all.count
                    quietSince = clock.now
                    continue
                }
                let waited = until.map { condition in all[consumed...].contains(where: condition) } ?? true
                if waited && clock.now - quietSince >= .milliseconds(300) { break }
            }
        } else {
            let wanted = steps < goldenSteps.count ? goldenSteps[steps].count { $0.hasPrefix("event ") } : 0
            let deadline = clock.now + .seconds(5)
            while Self.filter(Array(log.all[consumed...]), kept).count < wanted && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            // Any event past the ones expected shows up as a difference.
            try? await Task.sleep(for: .milliseconds(20))
        }
        let all = log.all
        lastEvents = Self.filter(Array(all[consumed...]), kept)
        consumed = all.count
        steps += 1
        lines += lastEvents.map { "event " + normalized(String(decoding: $0, as: UTF8.self)) }
    }

    /// Writes the golden file when recording, and otherwise compares the run with it.
    func finish() throws {
        let text = lines.joined(separator: "\n") + "\n"
        let file = Self.goldens.appending(path: "\(name).txt")
        if Self.isRecording {
            try FileManager.default.createDirectory(at: Self.goldens, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            return
        }
        guard let golden else {
            Issue.record("There's no golden file at \(file.path). Record one with REQLY_RECORD_WIRE_GOLDENS=1.")
            return
        }
        guard text != golden else { return }
        let actual = URL.temporaryDirectory.appending(path: "ReqlyWireGoldens/\(name).txt")
        try? FileManager.default.createDirectory(
            at: actual.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: actual)
        let wanted = golden.split(separator: "\n", omittingEmptySubsequences: false)
        let got = text.split(separator: "\n", omittingEmptySubsequences: false)
        let line =
            zip(wanted, got).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(wanted.count, got.count)
        Issue.record(
            """
            The wire differs from \(name).txt from line \(line + 1).
            Expected: \(line < wanted.count ? wanted[line] : "(the end)")
            Got:      \(line < got.count ? got[line] : "(the end)")
            The whole run is in \(actual.path).
            """)
    }

    // MARK: - What's kept, and how it's written

    static func filter(_ events: [Data], _ kept: Kept) -> [Data] {
        switch kept {
        case .all:
            events
        case .only(let names):
            events.filter { names.contains(kind($0).name) }
        case .allButOpeningSidebar:
            events.filter { kind($0) != ("sidebar", 0) }
        }
    }

    /// An event's kind, and the traffic it counts when it says.
    static func kind(_ event: Data) -> (name: String, total: Int?) {
        let object = (try? JSONSerialization.jsonObject(with: event)) as? [String: Any]
        return (object?["event"] as? String ?? "", object?["total"] as? Int)
    }

    static func json(_ fields: [String: Any]) -> String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        let data = try? JSONSerialization.data(withJSONObject: fields, options: options)
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// A value as the wire writes it, such as a rule set as the rules file keeps it.
    static func encoded(_ value: some Encodable) -> String {
        String(decoding: (try? Wire.encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    private func normalized(_ text: String, _ keys: [String] = []) -> String {
        var text = text
        for spelling in folderSpellings {
            text = text.replacingOccurrences(of: spelling, with: "$FOLDER")
        }
        text = text.replacing(#/\$FOLDER(?<rest>[^"\s]*)/#) { match in
            "$FOLDER" + match.output.rest.replacingOccurrences(of: #"\\"#, with: "/")
        }
        text = text.replacing(#/is missing something: (?:[^"\\]|\\.)*/#, with: "is missing something: $decodingError")
        let uuid = #/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#
        text = text.replacing(uuid) { match in
            let found = String(match.output).uppercased()
            if let known = uuids[found] { return known }
            let name = "$UUID\(uuids.count + 1)"
            uuids[found] = name
            return name
        }
        for key in keys {
            if let number = try? Regex(#""\#(key)":-?[0-9][0-9.eE+-]*"#) {
                text = text.replacing(number, with: #""\#(key)":$\#(key)"#)
            }
        }
        return text
    }
}

/// A root made once for these tests, "Reqly CA 2026-10-31 12:00", so HTTPS replies show the same
/// certificate each run. It's only ever a stand-in: the test's file store counts it as trusted, and
/// nothing else does.
enum FixedRoot {
    static let certificate = """
        MIIBrjCCAVWgAwIBAgIUIOzHT2OHW7GQWirV8UMVLGSqV8AwCgYIKoZIzj0EAwIwNDEiMCAGA1UEAwwZUmVxbHkgQ0EgMjAy
        Ni0xMC0zMSAxMjowMDEOMAwGA1UECgwFUmVxbHkwHhcNMjYxMDMwMTIwMDAwWhcNMjgxMDMwMTIwMDAwWjA0MSIwIAYDVQQD
        DBlSZXFseSBDQSAyMDI2LTEwLTMxIDEyOjAwMQ4wDAYDVQQKDAVSZXFseTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABGbE
        WMLvrjJw211Cb9p+De8cF2Tt7dNw/nHsRxjTb/jZf1B5L6oMg4YSbOFXEcv02d1f4WJqKbyh6QN2fXjQP02jRTBDMBIGA1Ud
        EwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBSpD0q36+PT0PIP5QmSy2QcRgPmrzAKBggqhkjOPQQD
        AgNHADBEAiBWf4pYzbKwDbbGMq6zEw0Om6gk8llXiWFF9XbZb6uLuwIgWwB5lMaO9yau5IosJ8bOxAxzDoGxeG0FzYebm5R+
        TLA=
        """
    static let key = "jQx1n9prapBTa+Kye9lIpiF9UW298qg0/ya/nVMK6RA="

    /// Writes the root where the stand-in store keeps it, as the store itself would.
    static func write(to file: URL) throws {
        let der = try #require(Data(base64Encoded: certificate.replacingOccurrences(of: "\n", with: "")))
        let list: [String: Data] = ["certificate": der, "key": try #require(Data(base64Encoded: key))]
        try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0).write(to: file)
    }
}

/// The saved session's exchanges: one of each thing the list, the details and the bodies show.
/// Bodies stay under 1,000 bytes, since bigger sizes are written with the computer's own decimal
/// separator.
enum WireTraffic {
    static let start = Date(timeIntervalSince1970: 1_793_448_000)

    static func exchange(
        _ id: UInt64, _ method: String, _ scheme: String, _ host: String, _ port: Int, _ target: String,
        headers: Headers = Headers()
    ) -> Exchange {
        var exchange = Exchange(
            id: ExchangeID(rawValue: id), connectionID: ConnectionID(rawValue: id), kind: .http,
            request: RequestHead(
                method: method, scheme: scheme, host: host, port: port, target: target, headers: headers),
            started: start + Double(id))
        exchange.state = .completed
        exchange.timing.ended = start + Double(id) + 0.25
        return exchange
    }

    static var exchanges: [Exchange] {
        let weather = Source(name: "Weather", path: #"C:\Apps\Weather.exe"#)

        var forecast = exchange(
            1, "GET", "https", "api.weatherly.dev", 443, "/v2/forecast?city=Tehran&units=metric",
            headers: ["Accept": "application/json", "Cookie": "session=abc; theme=dark", "Authorization": "Bearer xyz"])
        forecast.response = ResponseHead(
            status: 200, reason: "OK", version: "HTTP/2",
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": "session=new; Path=/; Secure; HttpOnly; Expires=Sat, 31 Oct 2026 13:00:00 GMT",
            ])
        let hourly = #"[{"time":"12:00","temp":18.5},{"time":"13:00","temp":19}]"#
        forecast.responseBody = Data(#"{"city":"Tehran","hourly":\#(hourly),"wind":"light"}"#.utf8)
        let begun = start + 1
        forecast.timing.requestEnded = begun + 0.0625
        forecast.timing.connectStarted = begun + 0.0625
        forecast.timing.resolved = begun + 0.125
        forecast.timing.connected = begun + 0.1875
        forecast.timing.secured = begun + 0.25
        forecast.timing.requestSent = begun + 0.3125
        forecast.timing.responseStarted = begun + 0.5
        forecast.timing.ended = begun + 0.75
        forecast.remoteAddress = "203.0.113.7:443"
        forecast.tlsVersion = "TLS 1.3"
        forecast.serverProtocol = "h2"
        forecast.bytesSent = 412
        forecast.bytesReceived = 960
        forecast.source = weather
        forecast.appliedRules = [
            AppliedRule(name: "Staging", kind: .mapRemote, detail: "Sent to https://staging.weatherly.dev/v2/forecast")
        ]
        forecast.scriptOutput = [ScriptOutput(rule: "Log", part: .request, lines: ["GET /v2/forecast"])]

        var report = exchange(
            2, "POST", "https", "api.weatherly.dev", 443, "/v2/report",
            headers: ["Content-Type": "application/x-www-form-urlencoded"])
        report.requestBody = Data("city=Lisbon&sky=sunny+and+warm".utf8)
        report.response = ResponseHead(status: 201, reason: "Created", headers: ["Content-Type": "text/plain"])
        report.responseBody = Data("Thanks".utf8)
        report.source = weather
        report.reusedConnection = true

        var protobuf = exchange(
            3, "GET", "https", "api.weatherly.dev", 443, "/v1/forecast", headers: ["Accept": "application/x-protobuf"])
        protobuf.response = ResponseHead(status: 200, reason: "OK", headers: ["Content-Type": "application/x-protobuf"])
        // A Forecast: city "Tehran" (field 1), days 3 (field 2).
        protobuf.responseBody = Data([0x0A, 0x06] + Array("Tehran".utf8) + [0x10, 0x03])

        var live = exchange(
            4, "GET", "https", "api.weatherly.dev", 443, "/v2/live",
            headers: ["Upgrade": "websocket", "Connection": "Upgrade"])
        live.response = ResponseHead(
            status: 101, reason: "Switching Protocols", headers: ["Upgrade": "websocket", "Connection": "Upgrade"])
        live.messageCount = messages.count

        var status = exchange(5, "GET", "http", "status.weatherly.dev", 80, "/v1/status")
        status.response = ResponseHead(status: 404, reason: "Not Found", headers: ["Content-Type": "application/json"])
        status.responseBody = Data(#"{"error":"missing"}"#.utf8)
        status.device = Device(
            id: "mac:aa:bb:cc:dd:ee:ff", kind: .network, name: "192.168.1.20", address: "192.168.1.20")

        var tunnel = exchange(6, "CONNECT", "https", "bank.example", 443, "bank.example:443")
        tunnel.kind = .tunnel
        tunnel.bytesSent = 900
        tunnel.bytesReceived = 4_200

        var image = exchange(7, "GET", "https", "images.weatherly.dev", 443, "/icons/sun.png")
        image.response = ResponseHead(status: 200, reason: "OK", headers: ["Content-Type": "image/png"])
        image.responseBody =
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52])
            + Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89])

        var alerts = exchange(
            8, "POST", "https", "api.weatherly.dev", 443, "/v2/alerts", headers: ["Content-Type": "application/json"])
        alerts.requestBody = Data(#"{"since":"12:00","cities":["Tehran","Oslo"]}"#.utf8)
        alerts.state = .failed(.serverClosed)

        return [forecast, report, protobuf, live, status, tunnel, image, alerts]
    }

    /// The WebSocket exchange's messages.
    static var messages: [WebSocketMessage] {
        let opened = start + 4.5
        return [
            WebSocketMessage(direction: .sent, kind: .text, time: opened, data: Data(#"{"subscribe":"Tehran"}"#.utf8)),
            WebSocketMessage(direction: .received, kind: .text, time: opened + 0.5, data: Data(#"{"temp":18}"#.utf8)),
            WebSocketMessage(direction: .received, kind: .binary, time: opened + 1, data: Data([0x01, 0x02, 0xFF])),
            WebSocketMessage(direction: .sent, kind: .close, time: opened + 2, data: Data("bye".utf8), closeCode: 1000),
        ]
    }

    /// Saves the exchanges as a session file in `folder`, as Reqly saves one.
    static func saveSession(in folder: URL) async throws -> URL {
        let store = try await TrafficStore.newSession(
            in: folder.appending(path: "Made"), with: exchanges, messages: [ExchangeID(rawValue: 4): messages])
        let file = folder.appending(path: "Weather.reqly")
        try await store.saveSession(to: file, hidingSecrets: false)
        store.discard()
        return file
    }
}
