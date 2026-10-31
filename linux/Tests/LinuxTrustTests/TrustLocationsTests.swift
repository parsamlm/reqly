import Foundation
import Testing

@testable import LinuxTrust

/// Finding the browsers' NSS databases and Firefox's profiles in a home folder made for the test.
@Suite struct TrustLocationsTests {
    @Test func findsOnlyTheBrowserDatabasesThatExist() throws {
        try Fixtures.withFolder { home throws in
            let locations = TrustLocations(environment: ["HOME": home.path])
            #expect(locations.browserDatabases().isEmpty)
            #expect(locations.newBrowserDatabase.path == home.appending(path: ".local/share/pki/nssdb").path)

            for path in [".pki/nssdb", "snap/chromium/current/.pki/nssdb"] {
                try FileManager.default.createDirectory(
                    at: home.appending(path: path), withIntermediateDirectories: true)
            }
            #expect(
                locations.browserDatabases().map(\.path) == [
                    home.appending(path: ".pki/nssdb").path,
                    home.appending(path: "snap/chromium/current/.pki/nssdb").path,
                ])
            try FileManager.default.createDirectory(
                at: home.appending(path: ".local/share/pki/nssdb"), withIntermediateDirectories: true)
            #expect(locations.browserDatabases().count == 3)
        }
    }

    @Test func followsXDGDataHome() throws {
        try Fixtures.withFolder { home throws in
            let data = home.appending(path: "data")
            let locations = TrustLocations(environment: ["HOME": home.path, "XDG_DATA_HOME": data.path])
            #expect(locations.newBrowserDatabase.path == data.appending(path: "pki/nssdb").path)
            // Not an absolute path, so unset.
            let relative = TrustLocations(environment: ["HOME": home.path, "XDG_DATA_HOME": "data"])
            #expect(relative.newBrowserDatabase.path == home.appending(path: ".local/share/pki/nssdb").path)
        }
    }

    @Test func readsProfilesIni() {
        let folder = URL(filePath: "/home/you/.mozilla/firefox", directoryHint: .isDirectory)
        let text = """
            [Install4F96D1932A9F858E]
            Default=abcd.default-release
            Locked=1

            [Profile1]
            Name=work
            IsRelative=0
            Path=/srv/profiles/work

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=abcd.default-release
            Default=1

            [General]
            StartWithLastProfile=1
            Version=2

            [Profile2]
            Name=no relative key
            Path = efgh.other
            """
        #expect(
            TrustLocations.profiles(in: text, folder: folder).map(\.path) == [
                "/srv/profiles/work", "/home/you/.mozilla/firefox/abcd.default-release",
                "/home/you/.mozilla/firefox/efgh.other",
            ])
        #expect(TrustLocations.profiles(in: "", folder: folder).isEmpty)
    }

    /// Every place Firefox keeps profiles: its own, the XDG one Firefox ESR 153 uses, the snap's
    /// and the Flatpak's. Only opened profiles, with a cert9.db, count.
    @Test func findsFirefoxProfilesWhereverFirefoxKeepsThem() throws {
        try Fixtures.withFolder { home throws in
            let folders = [
                ".mozilla/firefox", ".config/mozilla/firefox", ".local/share/mozilla/firefox",
                "snap/firefox/common/.mozilla/firefox", "snap/firefox/common/.config/mozilla/firefox",
                "snap/firefox/current/.config/mozilla/firefox", ".var/app/org.mozilla.firefox/.mozilla/firefox",
                ".var/app/org.mozilla.firefox/config/mozilla/firefox",
            ]
            var opened: [String] = []
            for (index, path) in folders.enumerated() {
                let folder = home.appending(path: path)
                try FileManager.default.createDirectory(
                    at: folder.appending(path: "p\(index).default"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(
                    at: folder.appending(path: "never-opened"), withIntermediateDirectories: true)
                _ = FileManager.default.createFile(
                    atPath: folder.appending(path: "p\(index).default/cert9.db").path, contents: nil)
                opened.append(folder.appending(path: "p\(index).default").path)
                try """
                [Profile0]
                Name=default
                IsRelative=1
                Path=p\(index).default

                [Profile1]
                Name=new
                IsRelative=1
                Path=never-opened
                """.write(to: folder.appending(path: "profiles.ini"), atomically: true, encoding: .utf8)
            }
            // A profile elsewhere, by its absolute path, listed twice.
            let elsewhere = home.appending(path: "elsewhere/profile")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: elsewhere.appending(path: "cert9.db").path, contents: nil)
            let ini = home.appending(path: ".mozilla/firefox/profiles.ini")
            try
                (try String(contentsOf: ini, encoding: .utf8)
                + "\n[Profile2]\nIsRelative=0\nPath=\(elsewhere.path)\n[Profile3]\nIsRelative=0\nPath=\(elsewhere.path)/\n")
                .write(to: ini, atomically: true, encoding: .utf8)

            let found = TrustLocations(environment: ["HOME": home.path]).firefoxProfiles().map(\.path)
            #expect(Set(found) == Set(opened + [elsewhere.path]))
            #expect(found.count == opened.count + 1)
        }
    }

    @Test func findsNoProfilesBeforeFirefoxRuns() throws {
        try Fixtures.withFolder { home throws in
            #expect(TrustLocations(environment: ["HOME": home.path]).firefoxProfiles().isEmpty)
        }
    }
}
