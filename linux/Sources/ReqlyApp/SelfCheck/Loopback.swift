import Foundation

/// TCP on 127.0.0.1, with plain sockets, so the app lookup sees this process's own connections.
enum Loopback {
    struct Failed: Error, CustomStringConvertible {
        var step: String
        var description: String { "\(step) failed: \(String(cString: strerror(errno)))" }
    }

    /// A socket listening on 127.0.0.1, on `port`, or one the kernel picks, and the port.
    static func listen(port: Int = 0) throws -> (socket: Int32, port: Int) {
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard listener >= 0 else { throw Failed(step: "socket") }
        var address = loopback(port: port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Glibc.listen(listener, 8) == 0 else {
            close(listener)
            throw Failed(step: "listening on port \(port)")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        return (listener, Int(UInt16(bigEndian: address.sin_port)))
    }

    /// A connection to `port` on 127.0.0.1 that gives up reading after five seconds.
    static func connect(to port: Int) throws -> Int32 {
        let client = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard client >= 0 else { throw Failed(step: "socket") }
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(client)
            throw Failed(step: "connecting to port \(port)")
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
