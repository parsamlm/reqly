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
                TrustPlace(kind: .firefox, status: .notTrusted, locations: Self.profiles), "Not trusted", true,
                "2 profiles. Restart Firefox afterwards."
            ),
            (
                TrustPlace(kind: .firefox, status: .notFound, locations: []), "Not found", false,
                "Open Firefox once, then come back."
            ),
            (
                TrustPlace(kind: .browsers, status: .trusted, locations: Self.database), "Trusted", false,
                "One certificate database. Restart your browsers afterwards."
            ),
            (
                TrustPlace(kind: .browsers, status: .notFound, locations: []), "Not found", false,
                "Open Chrome, or another browser built on it, once, then come back."
            ),
            (
                TrustPlace(
                    kind: .browsers, status: .unavailable("Needs the libnss3-tools package, which has certutil."),
                    locations: Self.database),
                "Unavailable", false, "Needs the libnss3-tools package, which has certutil."
            ),
            (
                TrustPlace(kind: .computer, status: .notTrusted, locations: Self.computer), "Not trusted", true,
                "This adds the certificate to this computer's list, for every account on it. Linux asks for an "
                    + "administrator's password."
            ),
            (
                TrustPlace(kind: .computer, status: .trusted, locations: Self.computer), "Trusted", false,
                "It's in this computer's list, for every account on it."
            ),
        ]
        for (place, status, canTrust, detail) in places {
            #expect(place.statusName == status, "\(place.kind) \(place.status)")
            #expect(place.canTrust == canTrust, "\(place.kind) \(place.status)")
            #expect(place.detail == detail, "\(place.kind) \(place.status)")
        }
        #expect(places.map(\.place.name).first == "Firefox")
        #expect(places.last?.place.name == "Command-line tools and most other apps")
    }

    /// The fix for each app none of the places reaches, with the certificate's paths quoted for
    /// the shell, since `Reqly CA.pem` has a space and a home folder may have a quote.
    @Test func givesTheFixForEachAppNoPlaceReaches() {
        let folder = URL(filePath: "/home/o'neil/.local/share/reqly")
        let apps = UncoveredApp.all(
            pemFile: folder.appending(path: "Reqly CA.pem"), bundleFile: folder.appending(path: "ca-certificates.crt"))
        #expect(
            apps.map(\.name) == [
                "Node from nodejs.org or nvm", "Python in a virtual environment", "Java you installed yourself",
                "Docker containers", "Snap and Flatpak browsers Reqly doesn't know about",
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
                RUN update-ca-certificates
                """)
        #expect(apps[4].fix == "/home/o'neil/.local/share/reqly/Reqly CA.pem")
        #expect(apps.allSatisfy { $0.detail.hasSuffix(":") })
    }
}
