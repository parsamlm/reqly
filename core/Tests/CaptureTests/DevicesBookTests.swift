import Capture
import Foundation
import ReqlyModel
import Testing

@Suite struct DevicesBookTests {
    @Test func asksOnceThenLetsInWhatYouAllow() {
        var book = DevicesBook()
        let phone = DevicesFile.identity(ip: "192.168.1.20", hardwareAddress: "aa:bb:cc:dd:ee:ff")
        #expect(phone == "mac:aa:bb:cc:dd:ee:ff")
        let notAllowed = book.admit(id: phone, address: "192.168.1.20", allowsNetworkDevices: false)
        #expect(notAllowed == .refuse)
        let first = book.admit(id: phone, address: "192.168.1.20", allowsNetworkDevices: true)
        #expect(first == .ask(isNewRequest: true))
        // Every connection from it waits on the same question.
        let again = book.admit(id: phone, address: "192.168.1.20", allowsNetworkDevices: true)
        #expect(again == .ask(isNewRequest: false))
        #expect(book.requests == [DevicesBook.Request(id: phone, address: "192.168.1.20")])
        book.decide(phone, allow: true, name: "  Parsa's phone  ")
        #expect(book.requests.isEmpty && book.known == [DevicesBook.Known(id: phone, address: "192.168.1.20")])
        #expect(book.device(atAddress: "192.168.1.20")?.name == "Parsa's phone")
        // Let in before, it's let in from a new address too, and even while devices aren't allowed.
        let moved = book.admit(id: phone, address: "192.168.1.31", allowsNetworkDevices: false)
        #expect(moved == .allow)
        #expect(book.contents.known.first?.address == "192.168.1.31")
        #expect(book.device(atAddress: "192.168.1.31")?.id == phone)

        book.forget(phone)
        #expect(book.known.isEmpty && book.device(atAddress: "192.168.1.31") == nil)
        #expect(book.names[phone] == "Parsa's phone")
        let forgotten = book.admit(id: phone, address: "192.168.1.31", allowsNetworkDevices: true)
        #expect(forgotten == .ask(isNewRequest: true))
    }

    @Test func turnsAwayWhatYouRefuseUntilReqlyQuits() {
        var book = DevicesBook()
        let tablet = DevicesFile.identity(ip: "192.168.1.21", hardwareAddress: nil)
        #expect(tablet == "ip:192.168.1.21")
        _ = book.admit(id: tablet, address: "192.168.1.21", allowsNetworkDevices: true)
        book.decide(tablet, allow: false)
        let refused = book.admit(id: tablet, address: "192.168.1.21", allowsNetworkDevices: true)
        #expect(refused == .refuse)
        _ = book.admit(id: "ip:192.168.1.22", address: "192.168.1.22", allowsNetworkDevices: true)
        _ = book.admit(id: "ip:192.168.1.23", address: "192.168.1.23", allowsNetworkDevices: true)
        let turnedAway = book.refuseAll()
        #expect(turnedAway == ["ip:192.168.1.22", "ip:192.168.1.23"] && book.requests.isEmpty)
        // Turned away isn't saved: opened again, Reqly asks again.
        var reopened = DevicesBook(book.contents)
        let askedAgain = reopened.admit(id: tablet, address: "192.168.1.21", allowsNetworkDevices: true)
        #expect(askedAgain == .ask(isNewRequest: true))
    }

    @Test func namesDevicesOfEveryKind() {
        var book = DevicesBook()
        let emulator = Device(id: "emulator:Pixel_9", kind: .emulator, name: "Pixel 9")
        let renamedBlank = book.rename(emulator.id, to: "   ")
        #expect(!renamedBlank)
        #expect(book.named(emulator).name == "Pixel 9")
        let renamed = book.rename(emulator.id, to: " Test phone ")
        #expect(renamed)
        #expect(book.named(emulator).name == "Test phone")
    }

    @Test func keepsWhatYouLetInAndTheNames() throws {
        let url = URL.temporaryDirectory.appending(path: "ReqlyTests-\(UUID().uuidString)/Devices.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(DevicesFile.load(from: url) == DevicesFile.Contents())
        let contents = DevicesFile.Contents(
            known: [DevicesBook.Known(id: "mac:aa:bb", address: "192.168.1.20")], names: ["mac:aa:bb": "Phone"])
        try DevicesFile.save(contents, to: url)
        #expect(DevicesFile.load(from: url) == contents)
        // From a newer Reqly, it's left alone, as if there were none.
        try Data(#"{"version": 2, "known": [], "names": {}}"#.utf8).write(to: url)
        #expect(DevicesFile.load(from: url) == DevicesFile.Contents())
        #expect(
            DevicesFile.listeningProblem(CaptureError.portInUse(9090))
                == "Another app uses port 9090 on the network, so devices can't connect.")
    }
}
