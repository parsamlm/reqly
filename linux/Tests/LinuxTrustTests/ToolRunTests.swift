import Foundation
import Testing

@testable import LinuxTrust

/// How Reqly runs certutil and pkexec: with nothing of its own inherited, a time limit, and no
/// proxy variables.
@Suite struct ToolRunTests {
    @Test func theToolInheritsOnlyItsThreeDescriptors() throws {
        // A pipe that isn't closed on exec, as a socket opened without care would be.
        var leaked: [Int32] = [0, 0]
        #expect(pipe(&leaked) == 0)
        defer { leaked.forEach { close($0) } }
        let ended = try Fixtures.run("/bin/sh", ["-c", "ls /proc/$$/fd"], input: "")
        #expect(ended.status == 0)
        let descriptors = String(decoding: ended.output, as: UTF8.self).split(separator: "\n").sorted()
        #expect(descriptors == ["0", "1", "2"])
    }

    @Test func passesInputAndKeepsOutputAndErrorsApart() throws {
        let ended = try Fixtures.run("/bin/sh", ["-c", "cat; echo oops >&2; exit 3"], input: "hello")
        #expect(ended.status == 3)
        #expect(String(decoding: ended.output, as: UTF8.self) == "hello")
        #expect(ended.errorText == "oops")
    }

    @Test func stopsAToolThatRunsTooLong() throws {
        let started = Date()
        #expect(throws: ToolRun.Failure.timedOut) {
            try ToolRun(path: "/bin/sleep", arguments: ["30"], environment: [:], timeLimit: 0.5).run()
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func saysWhenThereIsNoSuchTool() {
        #expect(throws: ToolRun.Failure.notFound) {
            try ToolRun(path: "/nowhere/certutil", arguments: [], environment: [:]).run()
        }
    }

    @Test func findsToolsOnThePathAndDropsProxyVariables() {
        #expect(ToolRun.find("sh", in: ["PATH": "relative:/bin"]) == "/bin/sh")
        #expect(ToolRun.find("no-such-tool", in: ["PATH": "/bin"]) == nil)
        let environment = ToolRun.withoutProxy([
            "http_proxy": "x", "HTTPS_PROXY": "x", "no_proxy": "x", "ALL_PROXY": "x", "NODE_USE_ENV_PROXY": "1",
            "HOME": "/home/you",
        ])
        #expect(environment == ["HOME": "/home/you"])
    }
}
