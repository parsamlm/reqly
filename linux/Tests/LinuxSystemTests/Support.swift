import CoreInterface
import Foundation
import Synchronization
import Testing

// The helpers the core interface's own tests have, for the tests of sessions with Linux's parts.

/// The events a session sent, as the app would get them.
final class EventLog: Sendable {
    private let events = Mutex<[Data]>([])

    func record(_ json: Data) {
        events.withLock { $0.append(json) }
    }

    var all: [[String: Any]] {
        events.withLock { $0 }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// Waits up to five seconds for an event that `matches` says is the one.
    func wait(for matches: ([String: Any]) -> Bool) async -> [String: Any]? {
        for _ in 0..<500 {
            if let event = all.last(where: matches) {
                return event
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

/// Reads a reply's result, or fails the test with its problem.
func result(_ reply: Data) throws -> [String: Any] {
    let object = try #require((try JSONSerialization.jsonObject(with: reply)) as? [String: Any])
    if let problem = object["problem"] {
        Issue.record("The call failed: \(problem)")
    }
    return try #require(object["result"] as? [String: Any])
}

func call(_ host: SessionHost, _ json: String) async -> Data {
    await host.reply(to: Data(json.utf8))
}

/// Runs `work`, which blocks while it waits, on a thread of its own, as the app calls the core from
/// threads of its own. Swift's tasks share as many threads as the computer has cores, four on
/// GitHub's, and work that blocks one holds up every test's tasks, and the core's.
func onOwnThread<T: Sendable, E: Error>(_ work: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
    let result = await withCheckedContinuation { (done: CheckedContinuation<Result<T, E>, Never>) in
        Thread.detachNewThread { done.resume(returning: Result(catching: work)) }
    }
    return try result.get()
}

/// A new empty folder for a test, which the test deletes.
func scratchFolder() throws -> URL {
    let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "reqly-system-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// TCP on 127.0.0.1, with plain sockets, so the app lookup sees this process's own connections.
enum Loopback {
    struct Failed: Error, CustomStringConvertible {
        var step: String
        var description: String { "\(step) failed: \(String(cString: strerror(errno)))" }
    }

    /// A socket listening on 127.0.0.1, on a port the kernel picks, and the port.
    static func listen() throws -> (socket: Int32, port: Int) {
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard listener >= 0 else { throw Failed(step: "socket") }
        var address = loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Glibc.listen(listener, 8) == 0 else {
            close(listener)
            throw Failed(step: "listen")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        return (listener, Int(UInt16(bigEndian: address.sin_port)))
    }

    /// A connection to `port` on 127.0.0.1 that gives up reading after `timeout` seconds.
    static func connect(to port: Int, timeout: Int = 5) throws -> Int32 {
        let client = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard client >= 0 else { throw Failed(step: "socket") }
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(client)
            throw Failed(step: "connect")
        }
        return client
    }

    static func write(_ text: String, to socket: Int32) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { send(socket, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            guard count > 0 else { return }
            offset += count
        }
    }

    /// What arrives on `socket` until `isWhole` says it's all there, the other end closes, or the
    /// time runs out.
    static func read(from socket: Int32, until isWhole: (String) -> Bool) -> String {
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isWhole(String(decoding: received, as: UTF8.self)) {
            let count = recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            received += buffer[..<count]
        }
        return String(decoding: received, as: UTF8.self)
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        return address
    }
}

/// A server on 127.0.0.1 that answers each request with "ok", one at a time, until it stops.
final class OkServer: Sendable {
    private let listener: Int32
    let port: Int

    init() throws {
        (listener, port) = try Loopback.listen()
        Thread.detachNewThread { [listener] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                _ = Loopback.read(from: client) { $0.contains("\r\n\r\n") }
                Loopback.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok", to: client)
                close(client)
            }
        }
    }

    /// Stops accepting, which ends the server's thread.
    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }
}
