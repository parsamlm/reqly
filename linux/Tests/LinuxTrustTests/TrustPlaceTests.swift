import Foundation
import Testing

@testable import LinuxTrust

/// What Set Up HTTPS and Settings › HTTPS show of each place, and what Reqly can do there.
@Suite struct TrustPlaceTests {
    static let profiles = [
        URL(filePath: "/home/ana/.config/mozilla/firefox/a.default-esr"),
        URL(filePath: "/home/ana/snap/firefox/common/.mozilla/firefox/b.default"),
    ]
    static let database = [URL(filePath: "/home/ana/.pki/nssdb")]
    static let computer = [URL(filePath: ComputerList.bundle)]

    @Test func saysEachStatusAndWhetherReqlyCanTrustIt() {
        let places: [(place: TrustPlace, status: String, canTrust: Bool, detail: String)] = [
            (
                TrustPlace(kind: .firefox, status: .notTrusted, locations: Self.profiles), "Not Trusted", true,
                "2 profiles. Restart Firefox afterwards."
            ),
            (
                TrustPlace(kind: .firefox, status: .notFound, locations: []), "Not Found", false,
                "Open Firefox once, then come back."
            ),
            (
                TrustPlace(kind: .browsers, status: .trusted, locations: Self.database), "Trusted", false,
                "One certificate database. Restart your browsers afterwards."
            ),
            (
                TrustPlace(kind: .browsers, status: .notFound, locations: []), "Not Found", false,
                "Open Chrome, or another browser built on it, once, then come back."
            ),
            (
                TrustPlace(
                    kind: .browsers, status: .unavailable("Needs the libnss3-tools package, which has certutil."),
                    locations: Self.database),
                "Unavailable", false, "Needs the libnss3-tools package, which has certutil."
            ),
            (
                TrustPlace(kind: .computer, status: .notTrusted, locations: Self.computer), "Not Trusted", true,
                "This adds the certificate to this computer's list, for every account on it. Linux asks for an "
                    + "administrator's password."
            ),
            (
                TrustPlace(kind: .computer, status: .trusted, locations: Self.computer), "Trusted", false,
                "It's in this computer's list, for every account on it."
            ),
            // Its key gone: setting up again takes the old one out, so the switch stays on.
            (
                TrustPlace(kind: .firefox, status: .trustsOldCertificate, locations: Self.profiles), "Old Certificate",
                true,
                "It still trusts Reqly's old certificate, which Reqly can't use without its key. Setting up HTTPS "
                    + "again takes it out."
            ),
            (
                TrustPlace(kind: .computer, status: .trustsOldCertificate, locations: Self.computer),
                "Old Certificate", true,
                "It still trusts Reqly's old certificate, for every account on it, though Reqly can't use it without "
                    + "its key. Setting up HTTPS again puts the new one in its place, and Linux asks for an "
                    + "administrator's password."
            ),
        ]
        for (place, status, canTrust, detail) in places {
            #expect(place.statusName == status, "\(place.kind) \(place.status)")
            #expect(place.canTrust == canTrust, "\(place.kind) \(place.status)")
            #expect(place.detail == detail, "\(place.kind) \(place.status)")
        }
        #expect(places.map(\.place.name).first == "Firefox")
        #expect(places.last?.place.name == "Command-line tools and most other apps")
        #expect(places.last?.place.title == "Command-Line Tools and Most Other Apps")
        #expect(places[2].place.title == "Chrome and Other Browsers Built on It")
    }

    /// The fix for each app none of the places reaches, with the certificate's paths quoted for
    /// the shell, since `Reqly CA.pem` has a space and a home folder may have a quote.
    @Test func givesTheFixForEachAppNoPlaceReaches() throws {
        let folder = URL(filePath: "/home/o'neil/.local/share/reqly")
        let apps = UncoveredApp.all(
            pemFile: folder.appending(path: "Reqly CA.pem"), bundleFile: folder.appending(path: "ca-certificates.crt"))
        #expect(
            apps.map(\.name) == [
                "Node From nodejs.org or nvm", "Python in a Virtual Environment", "Java You Installed Yourself",
                "Docker Containers", "Snap and Flatpak Browsers Reqly Doesn't Know About",
            ])
        let pem = #"'/home/o'\''neil/.local/share/reqly/Reqly CA.pem'"#
        #expect(apps[0].fix == "export NODE_EXTRA_CA_CERTS=\(pem)")
        #expect(apps[1].fix == #"export REQUESTS_CA_BUNDLE='/home/o'\''neil/.local/share/reqly/ca-certificates.crt'"#)
        #expect(
            apps[2].fix == "keytool -importcert -cacerts -storepass changeit -noprompt -alias reqly-ca -file \(pem)")
        #expect(apps[3].detail.contains("from /home/o'neil/.local/share/reqly beside its Dockerfile"))
        #expect(
            apps[3].fix == """
                COPY ["Reqly CA.pem", "/usr/local/share/ca-certificates/reqly-ca.crt"]
                RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \\
                    && update-ca-certificates
                """)
        #expect(apps[4].fix == "/home/o'neil/.local/share/reqly/Reqly CA.pem")
        #expect(apps.allSatisfy { $0.detail.hasSuffix(":") })

        // The Chromium snap comes first where it can't read certutil's trust, with the file to import.
        let withSnap = UncoveredApp.all(
            pemFile: folder.appending(path: "Reqly CA.pem"), bundleFile: folder.appending(path: "ca-certificates.crt"),
            chromiumSnap: true)
        #expect(withSnap.count == apps.count + 1)
        #expect(withSnap.first?.name == "Chromium From the Snap Store")
        #expect(withSnap.first?.fix == "/home/o'neil/.local/share/reqly/Reqly CA.pem")
        #expect(withSnap.first?.detail.hasSuffix(":") == true)
        // Chromium 156's own import, which asks nothing about trust, and its way back out.
        let snap = try #require(withSnap.first?.detail)
        #expect(
            snap.contains(
                "in Chromium's Settings › Privacy and security › Security › Manage certificates › Local certificates "
                    + "› Installed by you, click Import beside Trusted Certificates, then type or paste this path"))
        #expect(snap.contains("delete it there too when you remove it from Reqly"))
        #expect(!snap.contains("trust it to identify websites"))
    }
}
