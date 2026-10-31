import CoreInterface
import Foundation
import ReqlyCore
import Testing

/// The C functions, called as the app calls them.
@Suite struct ExportTests {
    /// Where a C callback puts what it gets: the context pointer leads back here.
    final class Inbox: Sendable {
        let events = EventLog()
        let replies = EventLog()
    }

    static let onEvent: ReqlyCallback = { json, context in
        guard let json, let context else { return }
        Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue().events.record(Data(String(cString: json).utf8))
    }

    static let onReply: ReqlyCallback = { json, context in
        guard let json, let context else { return }
        Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue().replies.record(Data(String(cString: json).utf8))
    }

    @Test func worksThroughTheCFunctions() async throws {
        let (folder, file) = try await Saved.file()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = Inbox()
        let context = Unmanaged.passRetained(inbox)
        defer { context.release() }
        let options = #"{"sessionsFolder":"\#(folder.appending(path: "Sessions").path)","file":"\#(file.path)"}"#
        // reqly_open waits for the core, so it runs on a thread of its own, as the app runs it away
        // from its UI thread. The handle crosses between threads as its address.
        let address = await onOwnThread { UInt(bitPattern: reqlyOpen(options, Self.onEvent, context.toOpaque())) }
        let handle = try #require(UnsafeMutableRawPointer(bitPattern: address))
        #expect(await inbox.events.wait { $0["event"] as? String == "rows" } != nil)

        reqlyCall(handle, #"{"call":"version"}"#, Self.onReply, context.toOpaque())
        let reply = try #require(await inbox.replies.wait { $0["result"] != nil })
        #expect((reply["result"] as? [String: Any])?["version"] as? Int == interfaceVersion)

        let body = await onOwnThread { () -> Data? in
            var length: Int64 = 0
            let handle = UnsafeMutableRawPointer(bitPattern: address)
            guard let bytes = reqlyBody(handle, 2, 1, 0, 1000, &length) else { return nil }
            defer { reqlyFree(bytes) }
            return Data(bytes: bytes, count: Int(length))
        }
        #expect(body == Data(#"["Tehran","Lisbon"]"#.utf8))

        await onOwnThread { reqlyClose(UnsafeMutableRawPointer(bitPattern: address)) }
    }

    @Test func saysWhyASessionDidntOpen() async {
        let inbox = Inbox()
        let context = Unmanaged.passRetained(inbox)
        defer { context.release() }
        let missing = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-\(UUID().uuidString)/Gone.reqly").path
        let sessions = URL.temporaryDirectory.appending(path: "ReqlyCoreTests-x").path
        let options = #"{"sessionsFolder":"\#(sessions)","file":"\#(missing)"}"#
        let address = await onOwnThread { UInt(bitPattern: reqlyOpen(options, Self.onEvent, context.toOpaque())) }
        #expect(address == 0)
        let failed = inbox.events.all.first { $0["event"] as? String == "openFailed" }
        #expect((failed?["problem"] as? [String: Any])?["code"] as? String == "failed")
        #expect(reqlyOpen("not json", Self.onEvent, context.toOpaque()) == nil)
        try? FileManager.default.removeItem(at: URL.temporaryDirectory.appending(path: "ReqlyCoreTests-x"))
    }
}
