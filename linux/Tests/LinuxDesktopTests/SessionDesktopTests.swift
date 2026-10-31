import CLinux
import Foundation
import LinuxDesktop
import Testing

@Suite struct SessionDesktopTests {
    @Test func readsTheDesktopsTheSessionNames() {
        #expect(SessionDesktop(currentDesktop: "ubuntu:GNOME") == SessionDesktop(currentDesktop: "GNOME"))
        #expect(SessionDesktop(currentDesktop: "ubuntu:GNOME").isGNOME)
        #expect(!SessionDesktop(currentDesktop: "ubuntu:GNOME").isKDE)
        #expect(SessionDesktop(currentDesktop: "KDE").isKDE)
        #expect(!SessionDesktop(currentDesktop: "X-Cinnamon").isGNOME)
        #expect(!SessionDesktop(currentDesktop: nil).isGNOME)
    }

    /// The watcher starts this way: it keeps none of Reqly's descriptors, and its pidfd says when
    /// it has ended.
    @Test func startsAProcessWithNothingInheritedAndSeesItEnd() throws {
        // A pipe that isn't closed on exec, as a socket Reqly opened without care would be.
        var inherited: [Int32] = [0, 0]
        #expect(pipe(&inherited) == 0)
        var output: [Int32] = [0, 0]
        #expect(pipe(&output) == 0)
        defer { [inherited[0], inherited[1], output[0]].forEach { close($0) } }

        let arguments = ["/bin/sh", "-c", "ls /proc/$$/fd"]
        let pid = try withCStrings(arguments) { argv in
            try withCStrings(["PATH=/usr/bin:/bin"]) { envp in
                let pid = reqly_spawn_detached("/bin/sh", argv, envp, output[1])
                guard pid > 0 else { throw POSIXError(POSIXErrorCode(rawValue: -pid) ?? .EIO) }
                return pid
            }
        }
        close(output[1])
        let pidfd = reqly_pidfd_open(pid)
        #expect(pidfd >= 0)
        defer { close(pidfd) }
        #expect(reqly_pidfd_wait(pidfd, 10_000) == 1)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)

        let listed = FileHandle(fileDescriptor: output[0]).readDataToEndOfFile()
        let descriptors = String(decoding: listed, as: UTF8.self).split(separator: "\n")
        #expect(descriptors.sorted() == ["0", "1", "2"])
        #expect(reqly_pidfd_open(pid) == -ESRCH)
    }

    /// `strings` as a NULL-ended array of C strings, for `body`.
    private func withCStrings<T>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) throws -> T) rethrows
        -> T
    {
        let copies = strings.map { strdup($0) } + [nil]
        defer { copies.forEach { free($0) } }
        return try body(copies)
    }
}
