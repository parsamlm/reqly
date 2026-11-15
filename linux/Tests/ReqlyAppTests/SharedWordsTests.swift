import Foundation
import ReqlyModel
import Testing

@testable import ReqlyApp

@Suite struct SharedWordsTests {
    /// The status line adds each feature's note after what capturing says, and its tooltip and
    /// screen readers have each note's sentence.
    @Test func addsTheStatusLinesNotes() {
        let plain = StatusLine(status: "Not capturing · Port 9090")
        #expect(plain.text == "Not capturing · Port 9090")
        #expect(plain.tooltip == plain.text)
        #expect(plain.description.isEmpty)
        let noted = StatusLine(
            status: "Capturing on port 9090",
            notes: [
                StatusNote(
                    text: "Via proxy.example.com:8080",
                    sentence: "Traffic goes through the upstream proxy at proxy.example.com:8080."),
                StatusNote(text: "Devices can connect", sentence: "Devices on this network can connect."),
            ])
        #expect(noted.text == "Capturing on port 9090 · Via proxy.example.com:8080 · Devices can connect")
        #expect(
            noted.tooltip
                == "Capturing on port 9090 · Via proxy.example.com:8080 · Devices can connect\n"
                + "Traffic goes through the upstream proxy at proxy.example.com:8080.\n"
                + "Devices on this network can connect.")
        #expect(
            noted.description
                == "Traffic goes through the upstream proxy at proxy.example.com:8080. Devices on this network can "
                + "connect.")
    }

    /// The rules' notes: the kinds that act on requests, in the Rules menu's order, said as their
    /// names need, then Slow Network, with its profile and what it slows.
    @Test func saysWhichRuleKindsAreOn() {
        #expect(RulesNotes.notes(kindsOn: [], network: NetworkConditions()).isEmpty)
        #expect(
            RulesNotes.notes(kindsOn: [.breakpoint], network: NetworkConditions()) == [
                StatusNote(
                    text: "Breakpoints on",
                    sentence: "Breakpoints are on, so their rules act on the requests they match.")
            ])
        #expect(
            RulesNotes.notes(kindsOn: [.mapLocal], network: NetworkConditions()).map(\.sentence) == [
                "Map Local is on, so its rules act on the requests they match."
            ])
        let lte = NetworkConditions(profile: .lte, hosts: ["api.weatherly.dev", " "])
        let several = RulesNotes.notes(kindsOn: [.block, .breakpoint, .slowNetwork, .rewrite], network: lte)
        #expect(several.map(\.text) == ["Breakpoints, Rewrite and Block on", "Slow Network: LTE"])
        #expect(
            several[0].sentence
                == "Breakpoints, Rewrite and Block are on, so their rules act on the requests they match.")
        #expect(several[1].sentence == "Slow Network slows traffic to api.weatherly.dev, with the LTE profile.")
        let two = NetworkConditions(profile: .threeG, hosts: ["api.weatherly.dev", "maps.weatherly.dev"])
        #expect(
            RulesNotes.notes(kindsOn: [.slowNetwork], network: two).map(\.sentence) == [
                "Slow Network slows traffic to 2 hosts, with the 3G profile."
            ])
        #expect(
            RulesNotes.notes(kindsOn: [.slowNetwork], network: NetworkConditions()).map(\.sentence) == [
                "Slow Network slows all traffic, with the 3G profile."
            ])
    }

    /// What needs you: a held request names its breakpoint, and says what waits; a device says
    /// where it is; each has the button that shows it, and an ID of its own.
    @Test func saysWhatNeedsYou() {
        let request = Attention(
            .paused(ExchangeID(rawValue: 7), breakpoint: "API", message: "GET https://api.weatherly.dev/v2/forecast"))
        #expect(request.title == "Request paused by breakpoint “API”")
        #expect(request.body == "GET https://api.weatherly.dev/v2/forecast waits until you continue it.")
        #expect(request.button == "Show")
        #expect(request.id == "paused-7")
        let response = Attention(.paused(ExchangeID(rawValue: 8), breakpoint: "Forecast", message: ""))
        #expect(response.body == "It waits until you continue it.")
        let device = Attention(deviceWaiting: "a1", address: "192.168.1.23")
        #expect(device.title == "A device wants to use Reqly")
        #expect(
            device.body == "A device at 192.168.1.23 wants to send its traffic through Reqly. Allow it only if it's "
                + "yours.")
        #expect(device.button == "Review…")
        #expect(device.id == "device-a1")
    }

    /// A notification while no Reqly window is active, a toast in one that is, unless it shows what
    /// needs you already.
    @Test func getsYourAttentionWhereYouAre() {
        #expect(AttentionWay.choose(activeWindowShowsIt: nil) == .notification)
        #expect(AttentionWay.choose(activeWindowShowsIt: false) == .toast)
        #expect(AttentionWay.choose(activeWindowShowsIt: true) == .nothing)
    }

    /// Ctrl+1 to Ctrl+5 choose the pages every request has, and Ctrl+6 Messages, which is between
    /// Response and Raw in the tabs.
    @Test func keysTheDetailsPages() {
        #expect(DetailsPane.Page.allCases == [.overview, .request, .response, .messages, .raw, .timing])
        #expect(DetailsPane.Page.always == [.overview, .request, .response, .raw, .timing])
        #expect(DetailsPane.Page.allCases.map(\.key) == [1, 2, 3, 6, 4, 5])
        #expect(DetailsPane.Page.messages.title == "Messages")
    }
}
