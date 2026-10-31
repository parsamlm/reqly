import CertificateAuthority
import Foundation
import Testing

@testable import LinuxTrust

/// `reqly --remove-certificate`'s account of each place, from a store whose key is in a file, a
/// stand-in for the computer's list, and a stand-in for pkexec, so nothing of the computer's own
/// changes.
@Suite struct RemovalReportTests {
    /// A home folder with no browser databases or Firefox profiles, a computer's list holding
    /// `listed`, and a pkexec that runs `pkexec`, as polkit would once you answered.
    func withStore(
        listing listed: RootIdentity? = nil, pkexec: String = "exit 0",
        _ body: (LinuxRootStore, URL) throws -> Void
    ) throws {
        try Fixtures.withFolder { home throws in
            let bin = home.appending(path: "bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let list = home.appending(path: "etc/ca-certificates.crt")
            try FileManager.default.createDirectory(
                at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (listed.map { PEM.encode(try $0.certificateDER) } ?? "").write(
                to: list, atomically: true, encoding: .utf8)
            try Fixtures.script("#!/bin/sh\n\(pkexec)\n", at: bin.appending(path: "pkexec"))
            try Fixtures.script("#!/bin/sh\nexit 0\n", at: bin.appending(path: "reqly-trust"))
            let store = LinuxRootStore(
                file: home.appending(path: ".local/share/reqly/Certificate.dat"), keyring: nil,
                helper: bin.appending(path: "reqly-trust").path, pkexec: bin.appending(path: "pkexec").path,
                environment: ["HOME": home.path, "PATH": bin.path], uid: 4250, computerBundle: list.path)
            try body(store, list)
        }
    }

    @Test func saysThereIsNothingToRemove() throws {
        try withStore { store, _ in
            let report = RemovalReport.remove(from: store)
            #expect(report.outcome == .nothing && report.isComplete)
            #expect(report.lines == ["There's no certificate to remove."])
        }
    }

    /// The computer's list trusted it, and pkexec's stand-in takes it out of the list.
    @Test func removesItFromEveryPlaceAndDeletesTheKey() throws {
        let root = try Fixtures.root(minute: 40)
        try withStore(listing: root) { store, list in
            try Fixtures.script("#!/bin/sh\n: > '\(list.path)'\n", at: URL(filePath: store.helper.pkexec))
            try store.save(root)
            let report = RemovalReport.remove(from: store)
            #expect(report.outcome == .removed && report.isComplete)
            #expect(
                report.lines == [
                    "Chrome and other browsers built on it: nothing to remove.",
                    "Firefox: nothing to remove.",
                    "Command-line tools and most other apps: removed.",
                    "Its key: deleted from \(store.file.path).",
                    "Removed Reqly's certificate.",
                ])
            #expect(try store.load() == nil)
        }
    }

    /// Closing the password dialog leaves the certificate in the computer's list, and its key,
    /// so running it again can finish.
    @Test func saysWhatIsLeftWhenThePasswordIsDeclined() throws {
        let root = try Fixtures.root(minute: 41)
        try withStore(listing: root, pkexec: "exit 126") { store, _ in
            try store.save(root)
            let report = RemovalReport.remove(from: store)
            #expect(report.outcome == .declined && !report.isComplete)
            #expect(
                report.lines == [
                    "Chrome and other browsers built on it: nothing to remove.",
                    "Firefox: nothing to remove.",
                    "Command-line tools and most other apps: still trusts it. You closed the password dialog.",
                    "Its key: still in \(store.file.path).",
                    "Reqly's certificate stays where it's still trusted: you closed the password dialog.",
                ])
            #expect(try store.load() != nil)
        }
    }

    /// Without certutil, a browser database can't be checked, and one Reqly added the
    /// certificate to holds up the removal.
    @Test func saysWhatItCouldNotCheck() throws {
        let root = try Fixtures.root(minute: 42)
        try withStore { store, _ in
            try FileManager.default.createDirectory(
                at: store.locations.home.appending(path: ".pki/nssdb"), withIntermediateDirectories: true)
            try store.save(root)
            let report = RemovalReport.remove(from: store)
            let needsCertutil = "Needs the libnss3-tools package, which has certutil."
            #expect(report.lines.first == "Chrome and other browsers built on it: couldn't check. \(needsCertutil)")
            #expect(report.lines[2] == "Command-line tools and most other apps: didn't trust it.")
            // Reqly never added it there, so the rest goes.
            #expect(report.outcome == .removed)
        }
    }

    @Test func saysWhenItCantReadTheKey() throws {
        try withStore { store, _ in
            try store.save(try Fixtures.root(minute: 43))
            chmod(store.file.path, 0o644)
            let report = RemovalReport.remove(from: store)
            #expect(!report.isComplete && report.lines.count == 1)
            #expect(report.lines[0].hasPrefix("Reqly couldn't read its certificate, so it can't remove it. "))
        }
    }
}
