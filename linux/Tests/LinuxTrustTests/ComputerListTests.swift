import CertificateAuthority
import Foundation
import Testing

@testable import LinuxTrust

@Suite struct ComputerListTests {
    @Test func keepsEachAccountsRootApart() {
        #expect(ComputerList.certificateFile(uid: 1000) == "/usr/local/share/ca-certificates/reqly/reqly-ca-1000.crt")
        #expect(ComputerList.linkedFile(uid: 1001) == "/etc/ssl/certs/reqly-ca-1001.pem")
    }

    @Test func findsACertificateInAListByItsBytes() throws {
        try Fixtures.withFolder { folder throws in
            let root = try Fixtures.root(minute: 10)
            let decoy = try Fixtures.root(minute: 10)
            let bundle = folder.appending(path: "ca-certificates.crt")
            try (PEM.encode(try decoy.certificateDER) + PEM.encode(try Fixtures.root(minute: 11).certificateDER))
                .write(to: bundle, atomically: true, encoding: .utf8)
            #expect(!ComputerList.contains(try root.certificateDER, bundle: bundle.path))
            #expect(ComputerList.contains(try decoy.certificateDER, bundle: bundle.path))
            #expect(!ComputerList.contains(try root.certificateDER, bundle: folder.appending(path: "none").path))
        }
    }

    @Test func givesCommandsToRunByHand() {
        let pemFile = URL(filePath: "/home/o'neil/.local/share/reqly/Reqly CA.pem")
        #expect(
            ComputerList.commandsToAdd(pemFile: pemFile, uid: 1000) == """
                sudo mkdir -p /usr/local/share/ca-certificates/reqly
                sudo tee /usr/local/share/ca-certificates/reqly/reqly-ca-1000.crt \
                < '/home/o'\\''neil/.local/share/reqly/Reqly CA.pem' > /dev/null
                sudo update-ca-certificates
                """)
        #expect(ComputerList.commandsToRemove(uid: 1000).contains("sudo update-ca-certificates --fresh"))
    }
}

/// pkexec's answers, from a stand-in for it: 126 when you close the dialog, 127 when
/// you aren't allowed or there's no dialog to ask in.
@Suite struct TrustHelperTests {
    struct Ran {
        var result: Result<Void, TrustProblem>
        var arguments: String
        var input: String
        /// Whether pkexec ran in a session of its own, away from any terminal.
        var leadsSession: Bool
    }

    /// Runs the helper through a pkexec that prints `said` to standard error and exits with
    /// `status`, after saving its arguments and standard input.
    func run(status: Int32, said: String = "", remove: Bool = false, asksInTerminal: Bool = false) throws -> Ran {
        try Fixtures.withFolder { folder throws in
            let bin = folder.appending(path: "bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try said.write(to: folder.appending(path: "said"), atomically: true, encoding: .utf8)
            try Fixtures.script(
                """
                #!/bin/sh
                echo "$@" > \(folder.path)/arguments
                cat > \(folder.path)/input
                cat \(folder.path)/said >&2
                awk '{ print ($6 == $1) }' /proc/$$/stat > \(folder.path)/leads-session
                exit \(status)
                """, at: bin.appending(path: "pkexec"))
            let helper = folder.appending(path: "reqly-trust")
            try Fixtures.script("#!/bin/sh\nexit 0\n", at: helper)
            var trustHelper = TrustHelper(
                path: helper.path, pkexec: bin.appending(path: "pkexec").path,
                environment: ["PATH": "/usr/bin:/bin"], uid: 1000)
            trustHelper.asksInTerminal = asksInTerminal
            let result = Result { () throws(TrustProblem) in
                if remove {
                    try trustHelper.remove()
                } else {
                    try trustHelper.add(pem: "PEM", pemFile: URL(filePath: "/home/you/Reqly CA.pem"))
                }
            }
            let arguments = (try? String(contentsOf: folder.appending(path: "arguments"), encoding: .utf8)) ?? ""
            let input = (try? String(contentsOf: folder.appending(path: "input"), encoding: .utf8)) ?? ""
            let session = try? String(contentsOf: folder.appending(path: "leads-session"), encoding: .utf8)
            return Ran(
                result: result, arguments: arguments.trimmingCharacters(in: .newlines), input: input,
                leadsSession: session == "1\n")
        }
    }

    @Test func passesTheCertificateOnStandardInput() throws {
        let added = try run(status: 0)
        #expect(throws: Never.self) { try added.result.get() }
        #expect(added.arguments.hasSuffix("reqly-trust add"))
        #expect(added.input == "PEM")
        #expect(added.leadsSession)
        let removed = try run(status: 0, remove: true)
        #expect(removed.arguments.hasSuffix("reqly-trust remove"))
        #expect(removed.input == "")
    }

    /// `reqly --remove-certificate` lets pkexec ask in its terminal, when there's no password
    /// dialog, so pkexec stays in the terminal's session.
    @Test func asksInTheTerminalOnlyWhenTold() throws {
        let removed = try run(status: 0, remove: true, asksInTerminal: true)
        #expect(throws: Never.self) { try removed.result.get() }
        #expect(!removed.leadsSession)
    }

    @Test func closingTheDialogCancels() throws {
        #expect(throws: TrustProblem.cancelled) { try run(status: 126).result.get() }
    }

    @Test func notAllowedIsNotAllowed() throws {
        let said = "Error executing command as another user: Not authorized"
        #expect(throws: TrustProblem.notAllowed) { try run(status: 127, said: said).result.get() }
    }

    @Test func withNoPasswordDialogItGivesTheCommands() throws {
        let said =
            "Error creating textual authentication agent: Error opening current controlling terminal for the "
            + "process (`/dev/tty'): No such device or address"
        let commands = ComputerList.commandsToAdd(pemFile: URL(filePath: "/home/you/Reqly CA.pem"), uid: 1000)
        #expect(throws: TrustProblem.noPasswordDialog(commands: commands)) {
            try run(status: 127, said: said).result.get()
        }
        #expect(throws: TrustProblem.noPasswordDialog(commands: ComputerList.commandsToRemove(uid: 1000))) {
            try run(status: 127, said: said, remove: true).result.get()
        }
    }

    @Test func theHelpersOwnFailureSaysWhy() throws {
        let failure = TrustProblem.failed(
            "Reqly's helper couldn't change this computer's list. reqly-trust: the certificate isn't Reqly's.")
        #expect(throws: failure) {
            try run(status: 1, said: "reqly-trust: the certificate isn't Reqly's.").result.get()
        }
    }

    @Test func saysWhatIsMissing() throws {
        try Fixtures.withFolder { folder throws in
            let pkexec = folder.appending(path: "pkexec").path
            let noPkexec = TrustHelper(path: "/bin/true", pkexec: pkexec, environment: [:], uid: 1000)
            #expect(noPkexec.unavailableReason?.contains("pkexec") == true)
            #expect(throws: TrustProblem.self) { try noPkexec.remove() }
            try Fixtures.script("#!/bin/sh\nexit 0\n", at: folder.appending(path: "pkexec"))
            let noHelper = TrustHelper(
                path: folder.appending(path: "reqly-trust").path, pkexec: pkexec, environment: [:], uid: 1000)
            #expect(noHelper.unavailableReason?.contains("isn't installed") == true)
        }
    }

    /// The dialog has no time limit, but whoever's waiting can stop it.
    @Test func stopsWaitingWhenCancelled() throws {
        try Fixtures.withFolder { folder throws in
            try Fixtures.script("#!/bin/sh\nexec sleep 30\n", at: folder.appending(path: "pkexec"))
            try Fixtures.script("#!/bin/sh\nexit 0\n", at: folder.appending(path: "reqly-trust"))
            let helper = TrustHelper(
                path: folder.appending(path: "reqly-trust").path, pkexec: folder.appending(path: "pkexec").path,
                environment: ["PATH": "/usr/bin:/bin"], uid: 1000)
            let cancellation = Cancellation()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
            let started = Date()
            #expect(throws: TrustProblem.cancelled) { try helper.remove(cancellation: cancellation) }
            #expect(Date().timeIntervalSince(started) < 10)
        }
    }
}
