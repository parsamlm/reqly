import Foundation
import NIOHTTP1

/// The page a phone or tablet opens at Reqly's address to set itself up: Reqly's certificate to
/// download, and the steps to trust it and to use the Mac as its proxy.
struct SetupPage {
    struct Answer {
        var status: HTTPResponseStatus
        var contentType: String
        var body: Data
        var headers: [(name: String, value: String)] = []
    }

    /// The certificate's path. Both iOS and Android take it in DER.
    static let certificatePath = "/reqly-ca.crt"

    /// The Mac's address as the device reached it, such as `192.168.1.125`.
    let host: String
    let port: Int
    /// Reqly's root certificate, once HTTPS is set up on the Mac.
    let certificate: (der: [UInt8], name: String)?
    let isAndroid: Bool

    /// The page for a request's head, with the address taken from its Host header. A Host
    /// header that isn't an address or a name shows as "this Mac's address".
    init(for head: HTTPRequestHead, port: Int, certificate: (der: [UInt8], name: String)?) {
        let hostHeader = head.headers.first(name: "Host") ?? ""
        var host = hostHeader
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") {
            host = String(host[..<colon])
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:[]"))
        let isAddress = !host.isEmpty && host.unicodeScalars.allSatisfy(allowed.contains)
        self.host = isAddress ? host : "this Mac's address"
        self.port = port
        self.certificate = certificate
        isAndroid = head.headers.first(name: "User-Agent")?.contains("Android") ?? false
    }

    func answer(for path: String) -> Answer {
        switch path {
        case "/", "/index.html":
            Answer(status: .ok, contentType: "text/html; charset=utf-8", body: Data(page.utf8))
        case Self.certificatePath:
            if let certificate {
                Answer(
                    status: .ok, contentType: "application/x-x509-ca-cert", body: Data(certificate.der),
                    headers: [("Content-Disposition", "attachment; filename=\"Reqly CA.crt\"")])
            } else {
                Answer(
                    status: .notFound, contentType: "text/plain; charset=utf-8",
                    body: Data("Set up HTTPS in Reqly on the Mac first.\n".utf8))
            }
        default:
            Answer(
                status: .notFound, contentType: "text/plain; charset=utf-8",
                body: Data("Reqly's setup page is at /.\n".utf8))
        }
    }

    private var page: String {
        let address = "<code>\(escaped(host))</code>"
        let port = "<code>\(self.port)</code>"
        let download: String
        let iPhoneSteps: [String]
        let androidSteps: [String]
        if let certificate {
            download = #"<a class="button" href="\#(Self.certificatePath)">Download the Certificate</a>"#
            iPhoneSteps = [
                "Tap <b>Download the Certificate</b>, then <b>Allow</b>.",
                "In Settings, tap <b>Profile Downloaded</b>, then <b>Install</b>.",
                "In Settings › General › About › Certificate Trust Settings, turn on <b>\(escaped(certificate.name))</b>.",
                "In Settings › Wi-Fi, tap ⓘ next to your network, then Configure Proxy › Manual. Enter server \(address) and port \(port).",
                "Had an earlier Reqly certificate? Remove its profile in Settings › General › VPN &amp; Device Management.",
            ]
            androidSteps = [
                "Tap <b>Download the Certificate</b>.",
                "In Settings, search for <b>CA certificate</b>, and install the file you downloaded.",
                "In your Wi-Fi network's settings, set Proxy to Manual, with host \(address) and port \(port).",
            ]
        } else {
            download =
                #"<p class="callout">To see HTTPS traffic, first set up HTTPS in Reqly on your Mac, with Capture › Decrypt HTTPS. Then open this page again.</p>"#
            iPhoneSteps = [
                "In Settings › Wi-Fi, tap ⓘ next to your network, then Configure Proxy › Manual. Enter server \(address) and port \(port)."
            ]
            androidSteps = [
                "In your Wi-Fi network's settings, set Proxy to Manual, with host \(address) and port \(port)."
            ]
        }
        let iPhone = section("iPhone and iPad", iPhoneSteps)
        let android = section(
            "Android", androidSteps,
            note:
                "On Android 7 and later, apps trust a certificate you install only if they opt in. Debug builds of your own apps can."
        )
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Set Up Reqly</title>
            <style>
            :root { color-scheme: light dark; --accent: #0B9A83; --text: #1D1D1F; --secondary: #6E6E73; --background: #F2F2F4; --card: #FFFFFF; }
            @media (prefers-color-scheme: dark) { :root { --accent: #2FB59B; --text: #F5F5F7; --secondary: #A1A1A6; --background: #000000; --card: #1C1C1E; } }
            body { margin: 0; font: 17px/1.45 -apple-system, system-ui, sans-serif; background: var(--background); color: var(--text); }
            main { max-width: 560px; margin: 0 auto; padding: 32px 20px 48px; }
            h1 { font-size: 28px; margin: 0 0 8px; }
            h2 { font-size: 19px; margin: 0 0 10px; }
            p { margin: 0 0 12px; }
            .lead, .note { color: var(--secondary); }
            .note { font-size: 14px; margin: 10px 0 0; }
            .button { display: block; text-align: center; background: var(--accent); color: #000000; text-decoration: none; font-weight: 600; padding: 14px; border-radius: 12px; margin: 20px 0 24px; }
            .callout { background: var(--card); border-radius: 12px; padding: 14px 16px; margin: 20px 0 24px; }
            section { background: var(--card); border-radius: 14px; padding: 18px 20px; margin-bottom: 16px; }
            ol { margin: 0; padding-left: 22px; }
            li { margin-bottom: 8px; }
            code { font: 15px ui-monospace, Menlo, monospace; background: rgba(127, 127, 127, 0.16); padding: 1px 5px; border-radius: 5px; }
            </style>
            </head>
            <body><main>
            <h1>Set up this device</h1>
            <p class="lead">Install Reqly's certificate and trust it, then use the Mac as this device's proxy. Reqly then shows the device's traffic, HTTPS included.</p>
            \(download)
            \(isAndroid ? android + iPhone : iPhone + android)
            <p class="note">When you're done, set the proxy back to Off.</p>
            </main></body>
            </html>
            """
    }

    private func section(_ title: String, _ steps: [String], note: String? = nil) -> String {
        let items = steps.map { "<li>\($0)</li>" }.joined()
        let note = note.map { #"<p class="note">\#($0)</p>"# } ?? ""
        return "<section><h2>\(title)</h2><ol>\(items)</ol>\(note)</section>\n"
    }

    private func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
