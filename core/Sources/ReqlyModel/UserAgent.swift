import Foundation

/// The app a request's User-Agent names, for traffic from a phone or an emulator, where Reqly
/// can't see which app opened the connection.
///
/// Apps that use Apple's networking send their name first, such as `Weather/1 CFNetwork/1498.700.2
/// Darwin/23.6.0`. Browsers send their own long form. An encrypted tunnel that isn't decrypted
/// has no User-Agent, so its app stays unknown.
public enum UserAgent {
    public static func app(from userAgent: String?) -> Source? {
        guard let userAgent = userAgent?.trimmingCharacters(in: .whitespaces), !userAgent.isEmpty else {
            return nil
        }
        if userAgent.hasPrefix("Mozilla/") {
            return browser(in: userAgent)
        }
        // The first product, such as `Weather/1` or `Google%20Maps/6.110`, or a word before a
        // version Apple's daemons leave out, as in `nsurlsessiond (unknown version) CFNetwork/…`.
        let first = userAgent.prefix { $0 != " " }
        let product = String(first.prefix { $0 != "/" })
        guard first.contains("/") || userAgent.contains("CFNetwork/") else { return nil }
        let name = (product.removingPercentEncoding ?? product).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !libraries.contains(name.lowercased()) else { return nil }
        // An app's ID, such as `com.apple.appstored`, is a name of its own too.
        let isIdentifier = name.split(separator: ".").count >= 3 && !name.contains(" ")
        return Source(name: name, bundleID: isIdentifier ? name : nil)
    }

    /// Networking libraries, which name themselves rather than the app that uses them.
    private static let libraries: Set<String> = [
        "cfnetwork", "dalvik", "okhttp", "java", "apache-httpclient", "go-http-client", "python-requests",
        "python-urllib", "axios", "node-fetch", "dart", "curl", "wget",
    ]

    /// The browser in a `Mozilla/5.0 (…)` User-Agent. A web view inside an app looks like a
    /// browser but names none, so it gives no app.
    private static func browser(in userAgent: String) -> Source? {
        let products: [(token: String, name: String, bundleID: String?)] = [
            ("CriOS/", "Chrome", "com.google.chrome.ios"),
            ("FxiOS/", "Firefox", "org.mozilla.ios.Firefox"),
            ("EdgiOS/", "Edge", "com.microsoft.msedge"),
            ("EdgA/", "Edge", "com.microsoft.emmx"),
            ("OPiOS/", "Opera", nil),
            ("OPR/", "Opera", nil),
            ("SamsungBrowser/", "Samsung Internet", "com.sec.android.app.sbrowser"),
        ]
        for product in products where userAgent.contains(product.token) {
            return Source(name: product.name, bundleID: product.bundleID)
        }
        let isApple = userAgent.contains("(iPhone") || userAgent.contains("(iPad") || userAgent.contains("(iPod")
        if isApple {
            return userAgent.contains("Version/") && userAgent.contains("Safari/")
                ? Source(name: "Safari", bundleID: "com.apple.mobilesafari") : nil
        }
        if userAgent.contains("Android") {
            // `; wv)` marks a web view.
            if userAgent.contains("; wv)") { return nil }
            if userAgent.contains("Firefox/") { return Source(name: "Firefox", bundleID: "org.mozilla.firefox") }
            if userAgent.contains("Chrome/") { return Source(name: "Chrome", bundleID: "com.android.chrome") }
        }
        return nil
    }
}
