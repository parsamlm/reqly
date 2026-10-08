import AppKit
import Foundation
import Observation

/// Offers to report Reqly's last crash on GitHub. Nothing is sent: Reqly opens a new issue in
/// the browser, filled in from the crash report macOS wrote, for you to read, change and submit.
@Observable
final class CrashReporter {
    /// A crash to offer to report.
    struct Report: Identifiable, Equatable {
        let id: String
        /// The report macOS wrote, to attach to the issue.
        let file: URL
        let date: Date
        let title: String
        /// The issue's text, in Markdown, as it opens on GitHub.
        let body: String
        /// Whether ReqlyHelper crashed, rather than the app.
        var isHelper = false
    }

    private(set) var report: Report?

    static let newIssue = URL(string: "https://github.com/parsamlm/reqly/issues/new")!

    init() {
        let defaults = UserDefaults.standard
        // macOS keeps the app's reports with the user's logs, and the helper's, which runs as
        // root, with the system's.
        var folders = [
            URL.libraryDirectory.appending(path: "Logs/DiagnosticReports", directoryHint: .isDirectory),
            URL(filePath: "/Library/Logs/DiagnosticReports", directoryHint: .isDirectory),
        ]
        var since = defaults.object(forKey: DefaultsKey.crashReportsCheckedAt) as? Date
        #if DEBUG
            if let path = defaults.string(forKey: DefaultsKey.crashReportsFolder) {
                // Any report in the folder, whenever it was made, and nothing remembered.
                folders = [URL(filePath: path, directoryHint: .isDirectory)]
                since = .distantPast
            } else {
                defaults.set(Date.now, forKey: DefaultsKey.crashReportsCheckedAt)
            }
        #else
            defaults.set(Date.now, forKey: DefaultsKey.crashReportsCheckedAt)
        #endif
        // The first time Reqly opens, crashes from before don't count.
        guard let since else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "net.reqly.Reqly"
        let reports = folders
        Task {
            let found = await Task.detached {
                Self.newestCrash(in: reports, since: since, bundleID: bundleID)
            }.value
            report = found
        }
    }

    /// Opens the new issue in the browser.
    func openIssue() {
        guard let report else { return }
        NSWorkspace.shared.open(Self.issueURL(title: report.title, body: report.body))
        self.report = nil
    }

    func dismiss() {
        report = nil
    }

    /// A new issue on GitHub, filled in. A body too long for a link is cut short.
    static func issueURL(title: String, body: String) -> URL {
        var lines = body.components(separatedBy: "\n")
        while true {
            var components = URLComponents(url: newIssue, resolvingAgainstBaseURL: false)!
            var text = lines.joined(separator: "\n")
            if lines.count < body.components(separatedBy: "\n").count {
                // Cut inside a block of frames: close it.
                if lines.count(where: { $0 == "```" }) % 2 == 1 {
                    text += "\n…\n```"
                }
                text += "\n\n<sub>Cut short to fit in a link.</sub>"
            }
            components.queryItems = [
                URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: text),
            ]
            guard let url = components.url else { return newIssue }
            // GitHub turns away links much longer than this.
            if url.absoluteString.utf8.count <= 7_500 || lines.count <= 1 {
                return url
            }
            lines.removeLast()
        }
    }

    /// An issue for a problem that isn't a crash.
    static var problemURL: URL {
        let body = """
            ### What happened
            <!-- What did you do, what did you expect, and what did Reqly do instead? -->


            ### Details
            - \(appVersion)
            - \(macOSVersion)
            """
        return issueURL(title: "", body: body)
    }

    private nonisolated static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Reqly \(version) (\(build))"
    }

    private nonisolated static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    // MARK: - Reading crash reports

    /// The newest crash report of this app or its helper made after `since`, ready to report.
    nonisolated static func newestCrash(in folders: [URL], since: Date, bundleID: String) -> Report? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        }
        let candidates =
            files
            .filter {
                let name = $0.lastPathComponent
                return (name.hasPrefix("Reqly-") || name.hasPrefix("ReqlyHelper-")) && $0.pathExtension == "ips"
            }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: keys).contentModificationDate, date > since else {
                    return nil
                }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, date) in candidates {
            if let report = report(from: url, date: date, bundleID: bundleID) {
                return report
            }
        }
        return nil
    }

    /// A crash report's facts, in words for an issue. It leaves out what could say who you are,
    /// such as file paths in your home folder and the Mac's identifiers.
    nonisolated static func report(from url: URL, date: Date, bundleID: String) -> Report? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let newline = text.firstIndex(of: "\n"),
            let header = json(text[..<newline]),
            let body = json(text[text.index(after: newline)...]),
            header["bug_type"] as? String == "309"
        else { return nil }
        // The helper's reports have no bundle identifier, but it lives inside the app.
        let isHelper =
            body["procName"] as? String == "ReqlyHelper"
            && (body["procPath"] as? String)?.hasSuffix(".app/Contents/MacOS/ReqlyHelper") == true
        guard isHelper || header["bundleID"] as? String == bundleID else { return nil }
        let name = isHelper ? "ReqlyHelper" : "Reqly"

        let version = header["app_version"] as? String ?? "?"
        let build = header["build_version"] as? String ?? "?"
        let exception = body["exception"] as? [String: Any] ?? [:]
        let kind = [exception["type"] as? String, (exception["signal"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        let images = body["usedImages"] as? [[String: Any]] ?? []

        var lines = [
            "### What happened",
            isHelper
                ? "<!-- What were you doing when it happened? For example: I started capturing. -->"
                : "<!-- What were you doing when Reqly quit? For example: I opened a large JSON response. -->",
            "",
            "",
            "### Crash details",
            "- \(name) \(version) (\(build))",
        ]
        if let os = header["os_version"] as? String {
            let model = body["modelCode"] as? String
            let cpu = body["cpuType"] as? String
            lines.append("- \(os)\([model, cpu].compactMap { $0 }.map { ", \($0)" }.joined())")
        }
        if !kind.isEmpty {
            lines.append("- \(kind)")
        }
        if let termination = body["termination"] as? [String: Any], let indicator = termination["indicator"] as? String
        {
            lines.append("- \(indicator)")
        }
        for messages in (body["asi"] as? [String: [String]] ?? [:]).values {
            for message in messages {
                lines.append("- \(sanitized(message))")
            }
        }

        let threads = body["threads"] as? [[String: Any]] ?? []
        if let faulting = body["faultingThread"] as? Int, faulting < threads.count {
            let thread = threads[faulting]
            let queue = (thread["queue"] as? String).map { ", on \($0)" } ?? ""
            lines += ["", "Thread \(faulting) crashed\(queue):", "```"]
            lines += frames(thread["frames"] as? [[String: Any]] ?? [], images: images)
            lines.append("```")
        }
        if let backtrace = body["lastExceptionBacktrace"] as? [[String: Any]], !backtrace.isEmpty {
            lines += ["", "Last exception backtrace:", "```"]
            lines += frames(backtrace, images: images)
            lines.append("```")
        }
        if let binary = images.first(where: { $0["name"] as? String == name }), let uuid = binary["uuid"] as? String {
            lines += ["", "<sub>From \(url.lastPathComponent). \(name)'s binary: \(uuid).</sub>"]
        }

        return Report(
            id: url.lastPathComponent, file: url, date: crashDate(header["timestamp"] as? String) ?? date,
            title: "Crash: \(kind.isEmpty ? "\(name) quit unexpectedly" : kind) in \(name) \(version)",
            body: lines.joined(separator: "\n"), isHelper: isHelper)
    }

    /// Up to 30 frames, one per line, such as `3  AppKit  -[NSView layout] + 72`. A frame
    /// without a symbol gives its offset in the binary, to look up with the build's symbols.
    private nonisolated static func frames(_ frames: [[String: Any]], images: [[String: Any]]) -> [String] {
        let shown = frames.prefix(30).enumerated().map { number, frame in
            let image = (frame["imageIndex"] as? Int).flatMap {
                $0 < images.count ? images[$0]["name"] as? String : nil
            }
            let place: String
            if let symbol = frame["symbol"] as? String {
                place = "\(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
            } else {
                place = "0x\(String(frame["imageOffset"] as? Int ?? 0, radix: 16))"
            }
            return "\(number)  \(image ?? "???")  \(place)"
        }
        return frames.count > 30 ? shown + ["… \(frames.count - 30) more"] : shown
    }

    /// When the crash happened, from a report's header, such as `2026-09-30 22:00:58.00 +0200`.
    private nonisolated static func crashDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter.date(from: text)
    }

    /// The text with the home folder's path left out.
    private nonisolated static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "/Users/…", options: .regularExpression)
    }

    private nonisolated static func json(_ text: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
