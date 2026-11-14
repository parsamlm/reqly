import Foundation
import Testing

@testable import ReqlyApp

@Suite struct WindowLayoutTests {
    static let english = Locale(identifier: "en_US")

    @Test func saysWhatTheListShowsAsTheMacDoes() {
        func title(shown: Int, inScope: Int, total: Int, capturing: Bool = false, saved: Bool = false) -> ListTitle {
            ListTitle(
                scope: "All Traffic", shown: shown, inScope: inScope, total: total, isCapturing: capturing,
                isSaved: saved, locale: Self.english)
        }
        #expect(title(shown: 0, inScope: 0, total: 0).title == "All Traffic")
        #expect(title(shown: 0, inScope: 0, total: 0).subtitle == "Not capturing")
        #expect(title(shown: 0, inScope: 0, total: 0, capturing: true).subtitle == "Waiting for traffic")
        #expect(title(shown: 0, inScope: 0, total: 0, saved: true).subtitle == "No requests")
        #expect(title(shown: 1, inScope: 1, total: 1).subtitle == "1 request")
        #expect(title(shown: 12_871, inScope: 12_871, total: 12_871).subtitle == "12,871 requests")
        #expect(title(shown: 3, inScope: 1_200, total: 1_500).subtitle == "3 of 1,200 requests")
        // A scope with nothing in it, in a session that has requests, counts its own.
        #expect(title(shown: 0, inScope: 0, total: 9, capturing: true).subtitle == "0 requests")
        #expect(ListTitle.requests(1, locale: Self.english) == "1 request")
        #expect(ListTitle.requests(100_000, locale: Self.english) == "100,000 requests")
    }

    @Test func opensSmallerThanTheScreen() {
        // Room for 1200 by 760, which is less than three quarters of a big screen.
        #expect(MainWindow.openingSize(within: (1920, 1048)) == (1200, 760))
        #expect(MainWindow.openingSize(within: (2560, 1400)) == (1200, 760))
        // A 1280 by 800 screen, without GNOME's top bar: the same shape, on three quarters of it.
        let laptop = MainWindow.openingSize(within: (1280, 768))
        #expect(laptop.width == 1078 && laptop.height == 683)
        #expect(laptop.width * laptop.height <= 1280 * 768 * 3 / 4)
        // 1280 by 800 at 125%, as the VMs had it.
        let scaled = MainWindow.openingSize(within: (1024, 608))
        #expect(scaled.width <= 1024 && scaled.height <= 608)
        #expect(scaled.width * scaled.height <= 1024 * 608 * 3 / 4)
        // Never smaller than GNOME's smallest window.
        #expect(MainWindow.openingSize(within: (400, 300)) == (360, 294))
    }
}
