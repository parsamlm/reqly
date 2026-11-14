import CGtk
import CoreInterface
import Foundation
import GtkBinding
import LinuxDesktop

extension SelfCheck {
    /// One instance and files from Files, as Windows' check of a file opened from File Explorer.
    static let openFilesParts: [Part] = [
        Part(name: "open-files", seconds: 90) { try await $0.checkOpenFiles() }
    ]

    /// A copy of Reqly, the only one under an ID of its own, started with `Windows.reqly` and
    /// asked to capture as it opens: it shows only the file's window, captures nothing and opens no
    /// connections, so it reads no secrets, and stays up. A second launch with `Mac 1.0.reqly`
    /// opens it there, and quits; a launch without files shows the live window, which captures
    /// then. The copy runs this part itself, given files: see ``checkFileLaunch()``. Once it ends,
    /// having closed its last window, every session's folder has gone and the stand-in has your
    /// settings again.
    func checkOpenFiles() async throws {
        if !app.options.files.isEmpty {
            try await checkFileLaunch()
            return
        }
        let id = "net.reqly.SelfCheck.Files\(getpid())"
        let first = try ChildFiles("files-first", in: scratch)
        try JSONEncoder().encode(Self.yourProxySettings).write(to: first.standIn)
        let windows = try Self.checkoutFile("core/Tests/TrafficStoreTests/Sessions/Windows.reqly")
        let mac = try Self.macSession()
        // In the scratch folder, which has the home and XDG folders, as the self-check needs.
        let report = scratch.appending(path: "open-files-\(UUID().uuidString).txt")
        let one = try ChildRun(
            first.arguments() + [
                "--app-id", id, "--starts-capturing", "yes", "--port", "0", "--smoke", report.path, "--smoke-parts",
                "open-files", windows.path,
            ], environment: ["GTK_A11Y": "none"])
        defer { one.stop() }
        try await until("the first Reqly to show Windows.reqly", seconds: 30) {
            FileManager.default.fileExists(atPath: report.path + ".shown")
        }
        note("the first Reqly, \(one.identifier), started with Windows.reqly")

        let second = try ChildFiles("files-second", in: scratch)
        let two = try ChildRun(second.arguments() + ["--app-id", id, mac.path])
        defer { two.stop() }
        let secondStatus = await two.wait()
        try require(
            secondStatus == 0, "the launch with Mac 1.0.reqly ended with \(secondStatus.map(String.init) ?? "a signal")"
        )
        try require(
            !FileManager.default.fileExists(atPath: second.sessions.path),
            "the launch with Mac 1.0.reqly opened a session")
        try await until("the first Reqly to open Mac 1.0.reqly", seconds: 20) {
            FileManager.default.fileExists(atPath: report.path + ".opened")
        }
        note("a launch with Mac 1.0.reqly, \(two.identifier), quit with status 0, with no session of its own")

        let third = try ChildFiles("files-third", in: scratch)
        let three = try ChildRun(third.arguments() + ["--app-id", id])
        defer { three.stop() }
        let thirdStatus = await three.wait()
        try require(
            thirdStatus == 0, "the launch without files ended with \(thirdStatus.map(String.init) ?? "a signal")")
        note("a launch without files, \(three.identifier), quit with status 0")

        let firstStatus = await one.wait()
        let lines = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
        for line in lines.split(separator: "\n").dropFirst() {
            note("first Reqly: \(line.trimmingCharacters(in: .whitespaces))")
        }
        let log = (try? String(contentsOf: first.folder.appending(path: "Reqly.log"), encoding: .utf8)) ?? ""
        let complaints = log.split(separator: "\n").filter { $0.contains("-CRITICAL **") || $0.contains("-WARNING **") }
        try require(complaints.isEmpty, "the first Reqly's log has \(complaints.joined(separator: " | "))")
        try require(
            firstStatus == 0 && lines.contains("PASS open-files"),
            "the first Reqly ended with \(firstStatus.map(String.init) ?? "a signal"), and its check didn't pass")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: first.sessions.path)) ?? []
        try require(left.isEmpty, "once it quit, its sessions folder has \(left.joined(separator: ", "))")
        try require(
            try DesktopProxyStandIn(file: first.standIn).read() == Self.yourProxySettings,
            "once it quit, the stand-in doesn't have your settings")
        try require(
            !FileManager.default.fileExists(atPath: first.restoreFile.path), "once it quit, its restore file is there")
        note("it quit with status 0, with every session's folder gone and your settings back")
    }

    /// The copy's side of open-files: started with a file, it shows only the file's window; the
    /// live session opens, but doesn't capture, though asked to, and opens no connections. Then
    /// the other launches' files and the live window come; closing the live window hides it and
    /// stops capturing; Show Live Traffic and New Request bring it back; the same file again
    /// brings its window forward; Ctrl+W's action closes a file's window; closing the last window
    /// quits.
    private func checkFileLaunch() async throws {
        try await until("the file's window") { app.fileWindows.first?.model.session != nil }
        let windows = try present(app.fileWindows.first, "there's no file window")
        try require(app.fileWindows.count == 1, "\(app.fileWindows.count) file windows show")
        try require(app.liveWindow == nil, "the live window was made")
        let title = string(gtk_window_get_title(cast(windows.window))) ?? ""
        try require(title == "Windows.reqly", "the file's window's title is \(title)")
        try await until("its requests") { windows.list.total > 0 }
        try require(!gtk_widget_get_visible(windows.captureBox).isTrue, "the file's window shows the capture switch")
        try require(!gtk_widget_get_visible(windows.rulesButton).isTrue, "the file's window shows the Rules button")
        let menu = menuActions(windows.menu)
        try require(menu.contains("app.show-live-traffic"), "its main menu has no Show Live Traffic: \(menu)")
        note("Windows.reqly's window: \(windows.list.total) requests, no capture switch or Rules button")
        let live = try await session()
        try await Task.sleep(for: .milliseconds(500))
        try require(model.capture == .stopped, "the live session captures, \(model.capture), with no live window")
        try require(model.connections == nil, "the connections opened, so the secrets were read, with no live window")
        try require(model.rules != nil && model.devices != nil, "the live session didn't open its rules and devices")
        note("the live session opened, with its rules and devices; it doesn't capture, and has no connections")
        _ = FileManager.default.createFile(atPath: report.path + ".shown", contents: nil)

        try await until("Mac 1.0.reqly from the second launch", seconds: 30) { app.fileWindows.count == 2 }
        let mac = app.fileWindows[1]
        try await until("Mac 1.0.reqly's requests") { mac.list.total > 0 }
        try require(app.liveWindow == nil, "the second launch made the live window")
        note("the second launch opened Mac 1.0.reqly here: \(mac.list.total) requests")
        _ = FileManager.default.createFile(atPath: report.path + ".opened", contents: nil)

        try await until("the live window from the launch without files", seconds: 30) {
            app.liveWindow?.isShowing == true
        }
        let liveWindow = try present(app.liveWindow, "there's no live window")
        try await until("capturing to start, as asked as Reqly opened") { model.capture == .capturing }
        try require(model.connections != nil, "the connections didn't open as the live window showed")
        note("the launch without files showed the live window: it captures, and opened the connections")

        gtk_window_close(cast(liveWindow.window))
        try await until("the live window to hide, and capturing to stop") {
            !liveWindow.isShowing && model.capture == .stopped
        }
        try require(app.liveWindow === liveWindow && model.session === live, "the live window or its session went")
        try require(
            try DesktopProxyStandIn(file: try standInFile()).read() == Self.yourProxySettings,
            "the stand-in doesn't have your settings once the live window hid")
        note("closing the live window hid it, stopped capturing and put the stand-in back; the session stays")

        gtk_window_present(cast(mac.window))
        activate("show-live-traffic")
        try await until("Show Live Traffic to bring the live window back") { liveWindow.isShowing }
        gtk_window_close(cast(liveWindow.window))
        try await until("the live window to hide again") { !liveWindow.isShowing }
        gtk_window_present(cast(windows.window))
        activate("new-request")
        try await until("New Request to bring the live window back") { liveWindow.isShowing }
        note("Show Live Traffic and New Request each brought the live window back")

        app.open([try Self.checkoutFile("core/Tests/TrafficStoreTests/Sessions/Windows.reqly")])
        try require(app.fileWindows.count == 2, "opening Windows.reqly again made a window: \(app.fileWindows.count)")
        note("opening Windows.reqly again brought its window forward")

        g_action_group_activate_action(cast(mac.window), "close", nil)
        try require(
            app.fileWindows.count == 1 && app.fileWindows.first === windows,
            "Ctrl+W's action didn't close Mac 1.0.reqly's window")
        g_action_group_activate_action(cast(liveWindow.window), "close", nil)
        try require(liveWindow.isShowing, "Ctrl+W's action hid the live window")
        note("Ctrl+W's action closed Mac 1.0.reqly's window, and left the live one")

        gtk_window_close(cast(liveWindow.window))
        try await until("the live window to hide a third time") { !liveWindow.isShowing }
        try require(!app.isQuitting, "Reqly quits with Windows.reqly's window still open")
        gtk_window_close(cast(windows.window))
        try require(app.isQuitting, "Reqly didn't quit as its last window closed")
        note("closing the last window quits")
    }

    /// The actions of a menu's entries, in its sections.
    private func menuActions(_ menu: OpaquePointer) -> [String] {
        var found: [String] = []
        let model: UnsafeMutablePointer<GMenuModel> = cast(menu)
        for index in 0..<g_menu_model_get_n_items(model) {
            if let section = g_menu_model_get_item_link(model, index, "section") {
                found += menuActions(cast(section))
                g_object_unref(raw(section))
            }
            if let value = g_menu_model_get_item_attribute_value(model, index, "action", nil) {
                found.append(string(g_variant_get_string(value, nil)) ?? "")
                g_variant_unref(value)
            }
        }
        return found
    }
}

extension gboolean {
    /// Whether GLib's gboolean says yes.
    fileprivate var isTrue: Bool { self != 0 }
}
