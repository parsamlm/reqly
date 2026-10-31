import CGtk
import CoreInterface
import Foundation
import GtkBinding
import LinuxApps
import LinuxDesktop
import ReqlyModel

extension SelfCheck {
    /// Capturing's parts: the switch, your desktop's proxy through its stand-in, the status line,
    /// Settings › General, putting settings back, one Reqly at a time, the terminal and which app
    /// sent each request. Copies of Reqly they start have files and stand-ins of their own.
    static let captureParts: [Part] = [
        Part(name: "port-in-use") { try await $0.checkPortInUse() },
        Part(name: "capture") { try await $0.checkCapture() },
        Part(name: "proxy-problem") { try await $0.checkProxyProblem() },
        Part(name: "status") { try await $0.checkStatus() },
        Part(name: "general") { try await $0.checkGeneral() },
        Part(name: "restore") { try await $0.checkRestore() },
        Part(name: "signals") { try await $0.checkSignals() },
        Part(name: "single-instance", seconds: 45) { try await $0.checkSingleInstance() },
        Part(name: "terminal") { try await $0.checkTerminal() },
        Part(name: "icons") { try await $0.checkIcons() },
    ]

    /// Your settings before Reqly, as the stand-in starts: GNOME through an office's proxy, and
    /// KDE's file, the same.
    static let yourProxySettings = DesktopProxySettings(
        gnome: GNOMEProxy(
            mode: .set("manual"), httpHost: .set("proxy.office.example"), httpPort: .set(3128),
            httpsHost: .set("proxy.office.example"), httpsPort: .set(3128)),
        kde: KDEProxy(
            fileExists: true, proxyType: "1", httpProxy: "http://proxy.office.example 3128",
            httpsProxy: "http://proxy.office.example 3128"))

    // MARK: - Capturing

    /// A port another app has makes capturing fail with the session's message, and the switch go
    /// back off, with your setting untouched. Once the port is free, capturing starts.
    func checkPortInUse() async throws {
        _ = try await switchReady()
        let port = model.port
        let standIn = try standInFile()
        try JSONEncoder().encode(Self.yourProxySettings).write(to: standIn)
        let before = try Data(contentsOf: standIn)
        let taken = try Loopback.listen(port: port)
        gtk_widget_activate(window.captureSwitch)
        try await until("capturing to fail") { model.problem != nil && model.capture == .stopped }
        close(taken.socket)
        let status = statusLine
        note("status line: \(status)")
        try require(
            status == "Reqly couldn't start capturing. Another app already uses port \(port).",
            "the status line says \(status)")
        try require(gtk_switch_get_active(cast(window.captureSwitch)) == 0, "the switch stayed on")
        try require(try Data(contentsOf: standIn) == before, "the stand-in changed")
        try require(
            !FileManager.default.fileExists(atPath: model.folders.proxyRestoreFile.path), "a restore file was left")

        try await setCapture(on: true)
        try await setCapture(on: false)
        note("once the port was free: captured on port \(port), then stopped")
    }

    /// The switch, reached with Tab and turned on from the keyboard, points the stand-in for your
    /// desktop's proxy, GNOME's and KDE's, at Reqly and keeps a restore file. A request from this
    /// process goes through Reqly to a server on 127.0.0.1, and its row names this process, with a
    /// program's icon. Turning the switch off puts the stand-in back exactly as it was.
    func checkCapture() async throws {
        let captureSwitch = try await switchReady()
        let standIn = try standInFile()
        let restoreFile = model.folders.proxyRestoreFile
        try JSONEncoder().encode(Self.yourProxySettings).write(to: standIn)

        gtk_window_set_focus(cast(window.window), nil)
        var presses = 0
        while gtk_window_get_focus(cast(window.window)) != captureSwitch, presses < 10 {
            gtk_widget_child_focus(window.window, GTK_DIR_TAB_FORWARD)
            presses += 1
        }
        try require(gtk_window_get_focus(cast(window.window)) == captureSwitch, "Tab doesn't reach the switch")
        note("keyboard: Tab reaches the capture switch after \(presses) press(es)")
        gtk_widget_activate(captureSwitch)
        try await until("capturing to start") { model.capture == .capturing || model.problem != nil }
        try require(model.isCapturing, model.problem ?? "capturing didn't start")
        let port = try present(model.listeningPort, "capturing has no port")
        try await until("the switch to have the keyboard's focus again", seconds: 2) {
            gtk_window_get_focus(cast(window.window)) == captureSwitch
        }
        let pointed = try DesktopProxyStandIn(file: standIn).read()
        try require(pointed.gnome?.pointsAtReqly(port: port) == true, "GNOME's stand-in doesn't point at Reqly")
        try require(pointed.kde?.pointsAtReqly(port: port) == true, "KDE's stand-in doesn't point at Reqly")
        try require(FileManager.default.fileExists(atPath: restoreFile.path), "there's no restore file")
        note("stand-in: GNOME's and KDE's point at 127.0.0.1:\(port), and the restore file is kept")
        note("status line: \(statusLine)")

        // The connection stays open, as an app's to its proxy does, since the kernel names a
        // socket's owner only while it's open.
        let server = try OkServer()
        defer { server.stop() }
        let client = try await onOwnThread { Result { try Loopback.connect(to: port) } }.get()
        defer { close(client) }
        let origin = "127.0.0.1:\(server.port)"
        let answer = await onOwnThread {
            Loopback.write(
                "GET http://\(origin)/self-check/capture HTTP/1.1\r\nHost: \(origin)\r\nUser-Agent: Reqly\r\n\r\n",
                to: client)
            return Loopback.read(from: client) { $0.hasSuffix("\r\n\r\nok") }
        }
        try require(answer.hasPrefix("HTTP/1.1 200"), "the request got \(answer.prefix(100))")

        let list = window.list
        var found: ExchangeSummary?
        try await until("the request's row, with its app and status") {
            found = (0..<list.count).lazy.compactMap(list.summary(at:)).first {
                $0.port == server.port && $0.target == "/self-check/capture" && $0.status == 200 && $0.source != nil
            }
            return found != nil
        }
        let row = try present(found, "there's no row")
        let text = RowText(row)
        let process = try present(Processes.read(getpid()), "this process can't be read")
        note("row: \(text.app) · \(text.method) · \(text.host) · \(text.path) · \(text.status) · \(text.size)")
        try require(text.app == process.name, "the row's app is \(text.app), not \(process.name)")
        try require(row.source?.path == process.path, "the row's program is \(row.source?.path ?? "none")")
        try require(text.method == "GET" && text.host == origin && text.path == "/self-check/capture", "\(text)")
        try require(text.status == "200" && text.size == "2 B", "the row's status is \(text.status), size \(text.size)")
        var icon: OpaquePointer?
        try await until("the row's app icon") {
            let image = list.cell(.app, of: row.id).flatMap { gtk_widget_get_first_child($0) }
            icon = image.flatMap { gtk_widget_get_visible($0) != 0 ? gtk_image_get_gicon(cast($0)) : nil }
            return icon != nil
        }
        let names = themedNames(try present(icon, "there's no icon"))
        note("app icon: \(names.joined(separator: ", "))")
        try require(names.first == AppIcon.genericName, "the app's icon isn't a program's")

        // An encrypted connection, which Reqly passes through untouched before HTTPS is set up.
        let tunnel = try await onOwnThread { Result { try Loopback.connect(to: port) } }.get()
        defer { close(tunnel) }
        let connected = await onOwnThread {
            Loopback.write("CONNECT \(origin) HTTP/1.1\r\nHost: \(origin)\r\n\r\n", to: tunnel)
            return Loopback.read(from: tunnel) { $0.contains("\r\n\r\n") }
        }
        try require(connected.hasPrefix("HTTP/1.1 200"), "CONNECT got \(connected.prefix(100))")
        var lock: Widget?
        try await until("the encrypted connection's row, with its lock") {
            let encrypted = (0..<list.count).lazy.compactMap(list.summary(at:)).first {
                $0.kind == .tunnel && $0.port == server.port
            }
            let image = encrypted.flatMap { list.cell(.status, of: $0.id) }.flatMap { gtk_widget_get_first_child($0) }
            lock = image.flatMap { gtk_widget_get_visible($0) != 0 ? $0 : nil }
            found = encrypted
            return lock != nil
        }
        let encrypted = RowText(try present(found, "there's no encrypted connection"))
        let lockName = string(gtk_image_get_icon_name(cast(lock))) ?? ""
        note("encrypted connection: \(encrypted.method) · \(encrypted.host) · \(encrypted.path) · \(lockName)")
        try require(encrypted.path == "Encrypted connection", "its path says \(encrypted.path)")
        try require(lockName == "channel-secure-symbolic", "its status shows \(lockName)")

        gtk_widget_activate(captureSwitch)
        try await until("capturing to stop") { model.capture == .stopped }
        try require(try hasYourSettings(standIn), "the stand-in isn't as it was")
        try require(!FileManager.default.fileExists(atPath: restoreFile.path), "the restore file is still there")
        note("stopped: the stand-in has your settings again, every key as it was, and the restore file is gone")
        note("status line: \(statusLine)")
    }

    /// When the stand-in can't be pointed at Reqly, or put back, the status line shows the
    /// session's problem, and the switch shows what's so: off, or still on.
    func checkProxyProblem() async throws {
        let captureSwitch = try await switchReady()
        let standIn = try standInFile()
        let folder = standIn.deletingLastPathComponent()
        // A folder where the stand-in should be, which Reqly can read nothing from or write to.
        try? FileManager.default.removeItem(at: standIn)
        try FileManager.default.createDirectory(at: standIn, withIntermediateDirectories: false)
        gtk_widget_activate(captureSwitch)
        try await until("capturing to fail") { model.problem != nil && model.capture == .stopped }
        try FileManager.default.removeItem(at: standIn)
        note("setting it failed: \(statusLine)")
        try require(statusLine.hasPrefix("Reqly couldn't start capturing"), "the status line says \(statusLine)")
        try require(gtk_switch_get_active(cast(captureSwitch)) == 0, "the switch stayed on")

        try JSONEncoder().encode(Self.yourProxySettings).write(to: standIn)
        try await setCapture(on: true)
        // Its folder takes no new files, so the stand-in can't be replaced.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        await model.setCapturing(false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        note("putting it back failed: \(statusLine)")
        try require(model.isCapturing, "capturing stopped with the stand-in still pointing at Reqly")
        try require(statusLine.hasPrefix("Reqly couldn't stop capturing"), "the status line says \(statusLine)")
        try require(gtk_switch_get_active(cast(captureSwitch)) != 0, "the switch went off")
        try await setCapture(on: false)
        try require(try hasYourSettings(standIn), "the stand-in isn't as it was")
        note("once it could: stopped, with the stand-in put back, and the status line says \(statusLine)")
    }

    /// The status line, while capturing and after, says which desktop's proxy setting Reqly set,
    /// by `XDG_CURRENT_DESKTOP` and the stand-in's parts: on GNOME and KDE, that apps keep the
    /// connections they had; elsewhere, to restart apps or use Open Terminal; and once capturing
    /// stops, which terminals' tabs keep Reqly's proxy, from stand-ins for them on `PATH`.
    func checkStatus() async throws {
        _ = try await switchReady()
        let standIn = try standInFile()
        let desktopProxy = model.desktopProxy
        let environment = desktopProxy.environment
        defer {
            desktopProxy.environment = environment
            model.changed()
        }
        let terminals = try scratchFolder("status")
        for program in ["gnome-terminal", "ptyxis"] {
            try writeProgram(terminals.appending(path: program), "#!/bin/sh\n")
        }
        desktopProxy.environment["PATH"] = terminals.path
        let port = model.port
        let gnomeOnly = DesktopProxySettings(gnome: GNOMEProxy(), kde: nil)
        let keepConnections =
            "Apps keep connections they already had open, so restart Firefox to capture all of its traffic"
        let restart = "Restart apps you opened earlier, or start them from Open Terminal"
        let cases = [
            ("ubuntu:GNOME", gnomeOnly, "Proxy set for GNOME · \(keepConnections)"),
            ("KDE", Self.yourProxySettings, "Proxy set for GNOME and KDE · \(keepConnections)"),
            ("XFCE", gnomeOnly, "Proxy set for GNOME · \(restart)"),
        ]
        let stopped =
            "Not capturing · Port \(port) · GNOME Terminal and Ptyxis tabs opened while capturing still point "
            + "at Reqly, so open a new tab"
        for (desktop, settings, said) in cases {
            desktopProxy.environment["XDG_CURRENT_DESKTOP"] = desktop
            try JSONEncoder().encode(settings).write(to: standIn)
            try await setCapture(on: true)
            let capturing = statusLine
            note("\(desktop), capturing: \(capturing)")
            try require(capturing == "Capturing on port \(port) · \(said)", "on \(desktop), it says \(capturing)")
            try await setCapture(on: false)
            try require(statusLine == stopped, "on \(desktop), once stopped, it says \(statusLine)")
        }
        note("once stopped: \(stopped)")
        desktopProxy.environment["PATH"] = "/nonexistent"
        model.changed()
        note("once stopped, with neither terminal: \(statusLine)")
        try require(statusLine == "Not capturing · Port \(port)", "with neither terminal, it says \(statusLine)")
    }

    /// Settings › General says which desktop settings capturing changes, keeps you from a port out
    /// of range, and saves the port you choose to Settings.json.
    func checkGeneral() async throws {
        let window = window
        try JSONEncoder().encode(Self.yourProxySettings).write(to: try standInFile())
        activate("settings")
        try await until("Settings to open") {
            window.settings.map { gtk_widget_get_mapped($0.dialog) != 0 } ?? false
        }
        let dialog = try present(window.settings?.dialog, "Settings closed")
        let group = try present(descendant(of: dialog, typed: "AdwPreferencesGroup"), "General has no group")
        let description = string(adw_preferences_group_get_description(cast(group))) ?? ""
        note("description: \(description)")
        try require(
            description == "While capturing, Reqly points GNOME's and KDE's proxy settings at itself, and puts yours "
                + "back when you stop, even if it quits unexpectedly.", "General says \(description)")
        let port = try present(descendant(of: dialog, typed: "AdwSpinRow"), "General has no port")
        let saved = model.settings.proxyPort
        gtk_editable_set_text(cast(port), "80")
        let problem = string(adw_action_row_get_subtitle(cast(port))) ?? ""
        note("port 80: \(problem)")
        try require(problem == "Enter a port from 1024 to 65535.", "port 80 says \(problem)")
        adw_spin_row_set_value(cast(port), 9300)
        try require(model.settings.proxyPort == 9300, "the port wasn't kept")
        let file = try Data(contentsOf: model.folders.settingsFile)
        let written = try JSONDecoder().decode(AppSettingsPort.self, from: file).proxyPort
        try require(written == 9300, "Settings.json has port \(written)")
        let subtitle = string(adw_action_row_get_subtitle(cast(port))) ?? ""
        note("port 9300: saved to Settings.json, and the row says: \(subtitle)")
        adw_spin_row_set_value(cast(port), Double(saved))
        await settle()
        adw_dialog_close(cast(dialog))
        try await until("Settings to close") { window.settings == nil }
    }

    // MARK: - Putting settings back, and one Reqly at a time

    /// A Reqly that opens puts back the stand-in a Reqly that ended while capturing left pointing
    /// at itself, before it captures anything.
    func checkRestore() async throws {
        let files = try ChildFiles("restore", in: scratch)
        try JSONEncoder().encode(Self.yourProxySettings).write(to: files.standIn)
        // As a Reqly capturing on port 47123 leaves it when it ends unexpectedly.
        let switcher = UserProxySwitch(
            settings: DesktopProxyStandIn(file: files.standIn), restoreFile: files.restoreFile)
        try await switcher.enable(port: 47123)
        try require(try DesktopProxyStandIn(file: files.standIn).read().pointsAtReqly(port: 47123), "nothing was left")
        let child = try ChildRun(files.arguments + ["--starts-capturing", "no"])
        defer { child.stop() }
        note("left behind: the stand-in points at port 47123; Reqly \(child.identifier) opens")
        try await until("the new Reqly to put the stand-in back", seconds: 20) {
            !FileManager.default.fileExists(atPath: files.restoreFile.path)
        }
        try require(try hasYourSettings(files.standIn), "the stand-in isn't as it was")
        note("put back as it was, every key, as Reqly opened")
        child.send(SIGTERM)
        let status = await child.wait()
        try require(status == 0, "it ended with \(status.map(String.init) ?? "a signal")")
    }

    /// SIGTERM, as logging out sends, ends a capturing Reqly as quitting does: its stand-in goes
    /// back as it was, and its session's folder goes.
    func checkSignals() async throws {
        let files = try ChildFiles("signals", in: scratch)
        try JSONEncoder().encode(Self.yourProxySettings).write(to: files.standIn)
        let child = try ChildRun(files.arguments + ["--starts-capturing", "yes", "--port", "0"])
        defer { child.stop() }
        var port: Int?
        try await until("Reqly \(child.identifier) to capture", seconds: 20) {
            let kept = try? Data(contentsOf: files.restoreFile)
            port = kept.flatMap { try? JSONDecoder().decode(Kept.self, from: $0).port }
            let pointed = try? DesktopProxyStandIn(file: files.standIn).read()
            return port.map { pointed?.pointsAtReqly(port: $0) == true } ?? false
        }
        note("Reqly \(child.identifier) captures on port \(port ?? 0), its stand-in pointing at it")
        child.send(SIGTERM)
        let status = await child.wait()
        try require(status == 0, "SIGTERM ended it with \(status.map(String.init) ?? "a signal")")
        try require(try hasYourSettings(files.standIn), "the stand-in isn't as it was")
        try require(!FileManager.default.fileExists(atPath: files.restoreFile.path), "the restore file is still there")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: files.sessions.path)) ?? []
        try require(left.isEmpty, "its sessions folder still has \(left.joined(separator: ", "))")
        note("SIGTERM: it ended with status 0, the stand-in back as it was, and no session left")
    }

    /// Two runs under the same application ID: the second hands its launch to the first, which
    /// brings its window back, and quits without opening a session. The first is a copy of Reqly
    /// running this part itself, which, given `--app-id`, waits to be brought back.
    func checkSingleInstance() async throws {
        if app.options.appID != nil {
            try await waitToBeBroughtBack()
            return
        }
        let id = "net.reqly.SelfCheck.Run\(getpid())"
        let first = try ChildFiles("first", in: scratch)
        let second = try ChildFiles("second", in: scratch)
        let report = first.folder.appending(path: "Report.txt")
        let one = try ChildRun(
            first.arguments + ["--app-id", id, "--smoke", report.path, "--smoke-parts", "single-instance"])
        defer { one.stop() }
        try await until("the first Reqly to be ready", seconds: 20) {
            FileManager.default.fileExists(atPath: report.path + ".ready")
        }
        let two = try ChildRun(second.arguments + ["--app-id", id])
        defer { two.stop() }
        let secondStatus = await two.wait()
        try require(secondStatus == 0, "the second ended with \(secondStatus.map(String.init) ?? "a signal")")
        try require(
            !FileManager.default.fileExists(atPath: second.sessions.path), "the second opened a session of its own")
        note("the second Reqly, \(two.identifier), quit with status 0, with no session of its own")
        let firstStatus = await one.wait()
        let lines = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
        for line in lines.split(separator: "\n").dropFirst() {
            note("first Reqly, \(one.identifier): \(line.trimmingCharacters(in: .whitespaces))")
        }
        try require(firstStatus == 0 && lines.contains("PASS single-instance"), "the first wasn't brought back")
    }

    /// The first run's side of single-instance: says it's ready, then waits for another launch to
    /// activate it.
    private func waitToBeBroughtBack() async throws {
        var activations = 0
        connect(app.application, "activate") { activations += 1 }
        _ = FileManager.default.createFile(atPath: report.path + ".ready", contents: nil)
        try await until("another launch to bring this Reqly back", seconds: 30) { activations > 0 }
        note("another launch brought this Reqly's window back")
    }

    // MARK: - The terminal

    /// Copy Terminal Setup copies the lines for bash and for fish. Open Terminal starts the
    /// terminal it finds, a stand-in here that writes down how it was started, with your shell
    /// through `env` and the variables, and the session's environment without the proxy
    /// variables. With no terminal, it says which ones Reqly looks for.
    func checkTerminal() async throws {
        let port = model.port
        let setup = TerminalSetup(port: port, certificates: terminalCertificates())
        window.copyTerminalSetup(shell: "/bin/bash")
        let bash = await clipboardText()
        try require(bash == setup.text(for: .posix), "bash's lines are \(bash)")
        try require(
            bash.hasPrefix("export http_proxy=http://127.0.0.1:\(port) https_proxy=http://127.0.0.1:\(port)\n"),
            "bash's lines start \(bash.prefix(80))")
        note("bash: \(bash.split(separator: "\n").first ?? "")")
        note("certificate variables: \(setup.certificates == nil ? "none, before HTTPS is set up" : "included")")
        window.copyTerminalSetup(shell: "/usr/bin/fish")
        let fish = await clipboardText()
        try require(fish == setup.text(for: .fish), "fish's lines are \(fish)")
        try require(fish.hasPrefix("set -gx http_proxy http://127.0.0.1:\(port)\n"), "fish's lines start \(fish)")
        note("fish: \(fish.split(separator: "\n").first ?? "")")

        let folder = try scratchFolder("terminal")
        let launch = folder.appending(path: "launch.txt")
        try writeProgram(
            folder.appending(path: "xdg-terminal-exec"),
            "#!/bin/sh\n{ printf '%s\\n' \"$@\"; echo --; env; } > \"\(launch.path).part\"\n"
                + "mv \"\(launch.path).part\" \"\(launch.path)\"\n")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = folder.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["XDG_CURRENT_DESKTOP"] = "ubuntu:GNOME"
        environment["SHELL"] = "/bin/bash"
        // As if Reqly had been started from a terminal set up for it.
        environment["http_proxy"] = "http://127.0.0.1:1"
        window.openTerminal(environment: environment)
        try await until("the terminal to start") { FileManager.default.fileExists(atPath: launch.path) }
        let lines = try String(contentsOf: launch, encoding: .utf8).split(
            separator: "\n", omittingEmptySubsequences: false)
        let split = try present(lines.firstIndex(of: "--"), "the terminal wrote no arguments")
        let arguments = lines[..<split].map(String.init)
        let variables = Dictionary(
            lines[(split + 1)...].compactMap { line in
                line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) }
            }
        ) { first, _ in first }
        let expected = Terminal.command(setup: setup, shell: "/bin/bash")
        note("Open Terminal: xdg-terminal-exec \(arguments.joined(separator: " "))")
        try require(arguments == expected, "the terminal ran \(arguments)")
        try require(variables["XDG_CURRENT_DESKTOP"] == "ubuntu:GNOME", "the terminal lost XDG_CURRENT_DESKTOP")
        try require(variables["http_proxy"] == nil, "the terminal itself got http_proxy")
        note("its environment: the session's, with XDG_CURRENT_DESKTOP and without the proxy variables")

        environment["PATH"] = folder.appending(path: "nothing").path
        window.openTerminal(environment: environment)
        let alert = try present(adw_application_window_get_visible_dialog(cast(window.window)), "nothing was said")
        let body = string(adw_alert_dialog_get_body(cast(alert))) ?? ""
        note("no terminal: \(string(adw_alert_dialog_get_heading(cast(alert))) ?? ""): \(body)")
        try require(body == TerminalWords.noTerminal, "with no terminal, it says \(body)")
        await settle()
        adw_dialog_close(alert)
        try await until("the alert to close") { adw_application_window_get_visible_dialog(cast(window.window)) == nil }
    }

    // MARK: - App icons

    /// Desktop entries in your own applications folder name an icon in the theme and an image
    /// file, and apps with their desktop IDs get those icons. A tool gets a program's icon. Each
    /// app's icon is made once.
    func checkIcons() async throws {
        let data = try present(ProcessInfo.processInfo.environment["XDG_DATA_HOME"], "there's no XDG_DATA_HOME")
        let applications = URL(filePath: data).appending(path: "applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let image = try scratchFolder("icons").appending(path: "self-check.svg")
        try "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='16' height='16'/></svg>"
            .write(to: image, atomically: true, encoding: .utf8)
        let themedID = "net.reqly.SelfCheck.Themed"
        let fileID = "net.reqly.SelfCheck.File"
        for (id, icon) in [(themedID, "utilities-terminal"), (fileID, image.path)] {
            try "[Desktop Entry]\nType=Application\nName=\(id)\nExec=/usr/bin/\(id)\nIcon=\(icon)\n"
                .write(to: applications.appending(path: "\(id).desktop"), atomically: true, encoding: .utf8)
        }
        let icons = window.list.icons
        let entries = icons.entries
        // The entries are read again once their folder has changed, a few seconds at most.
        let deadline = monotonicMicroseconds() + 10_000_000
        while await !onOwnThread({ entries.entry(id: themedID) != nil && entries.entry(id: fileID) != nil }) {
            try require(monotonicMicroseconds() < deadline, "the entries weren't read")
            try await Task.sleep(for: .milliseconds(200))
        }

        let themedSource = Source(name: "Themed", bundleID: themedID, path: "/usr/bin/\(themedID)")
        let themed = try await icon(for: themedSource, in: icons)
        note("Icon=utilities-terminal: \(typeName(raw(themed))) \(themedNames(themed).joined(separator: ", "))")
        try require(typeName(raw(themed)) == "GThemedIcon", "it's a \(typeName(raw(themed)))")
        try require(themedNames(themed).first == "utilities-terminal", "it names \(themedNames(themed))")

        let file = try await icon(for: Source(name: "File", bundleID: fileID), in: icons)
        let path =
            typeName(raw(file)) == "GFileIcon" ? takeString(g_file_get_path(g_file_icon_get_file(cast(file)))) : nil
        note("Icon=\(image.path): \(typeName(raw(file))) \(path ?? "")")
        try require(path == image.path, "the image file's icon is a \(typeName(raw(file)))")

        let tool = try await icon(for: Source(name: "curl", path: "/usr/bin/curl"), in: icons)
        note("curl, a tool: \(typeName(raw(tool))) \(themedNames(tool).joined(separator: ", "))")
        try require(themedNames(tool).first == AppIcon.genericName, "the tool's icon names \(themedNames(tool))")
        try require(icons.icon(for: themedSource) == themed, "the icon was made again")
        note("found once: the same icon the second time")
    }

    // MARK: - What the parts share

    /// `value`, or the part fails, saying `failure`.
    private func present<Value>(_ value: Value?, _ failure: @autoclosure () -> String) throws -> Value {
        guard let value else { throw Failure(failure()) }
        return value
    }

    /// The self-check's scratch folder, which self-check.sh deletes.
    private var scratch: URL { report.deletingLastPathComponent() }

    /// A new folder in the scratch folder.
    private func scratchFolder(_ name: String) throws -> URL {
        let folder = scratch.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeProgram(_ file: URL, _ script: String) throws {
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// Whether a stand-in has your settings, every key as it was. JSONEncoder doesn't keep keys in
    /// one order, so the file's bytes may differ.
    private func hasYourSettings(_ standIn: URL) throws -> Bool {
        try DesktopProxyStandIn(file: standIn).read() == Self.yourProxySettings
    }

    /// The run's stand-in for your desktop's proxy setting.
    private func standInFile() throws -> URL {
        URL(filePath: try present(model.options.proxySettingsStandIn, "the run has no --proxy-settings-stand-in"))
    }

    /// The capture switch, once the session is open and it can be used.
    private func switchReady() async throws -> Widget {
        _ = try await session()
        let captureSwitch = window.captureSwitch
        try await until("the capture switch") { gtk_widget_get_sensitive(captureSwitch) != 0 }
        return captureSwitch
    }

    /// Starts or stops capturing, as the switch does, and fails unless it did.
    private func setCapture(on: Bool) async throws {
        await model.setCapturing(on)
        try require(model.capture == (on ? .capturing : .stopped), model.problem ?? "capturing didn't change")
    }

    private var statusLine: String {
        string(gtk_label_get_text(cast(window.statusLabel))) ?? ""
    }

    /// The first widget of a type under `root`, depth first.
    private func descendant(of root: Widget, typed name: String) -> Widget? {
        var child = gtk_widget_get_first_child(root)
        while let widget = child {
            if typeName(raw(widget)) == name {
                return widget
            }
            if let found = descendant(of: widget, typed: name) {
                return found
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return nil
    }

    /// An app's icon, once it's found.
    private func icon(for source: Source, in icons: AppIcons) async throws -> OpaquePointer {
        var icon: OpaquePointer?
        try await until("\(source.name)'s icon") {
            icon = icons.icon(for: source)
            return icon != nil
        }
        return try present(icon, "there's no icon")
    }

    /// A themed icon's names, in the order GTK tries them, or none for another kind of icon.
    private func themedNames(_ icon: OpaquePointer) -> [String] {
        guard typeName(raw(icon)) == "GThemedIcon", var names = g_themed_icon_get_names(cast(icon)) else { return [] }
        var found: [String] = []
        while let name = names.pointee {
            found.append(String(cString: name))
            names += 1
        }
        return found
    }

    /// The text on the window's clipboard.
    private func clipboardText() async -> String {
        let clipboard = gtk_widget_get_clipboard(window.window)
        return await withCheckedContinuation { done in
            let (callback, context) = whenReady { _, result in
                var error: UnsafeMutablePointer<GError>?
                let text = takeString(gdk_clipboard_read_text_finish(clipboard, result, &error))
                done.resume(returning: text ?? message(error))
            }
            gdk_clipboard_read_text_async(clipboard, nil, callback, context)
        }
    }
}

/// What a restore file says of the port Reqly captured on.
private struct Kept: Decodable {
    var port: Int
}

/// The port Settings.json keeps.
private struct AppSettingsPort: Decodable {
    var proxyPort: Int
}

/// The files a copy of Reqly that a part starts keeps, in a folder of its own: its own settings
/// and stand-ins, as the self-check has, and its log.
private struct ChildFiles {
    let folder: URL

    init(_ name: String, in scratch: URL) throws {
        folder = scratch.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var standIn: URL { folder.appending(path: "ProxySettings.json") }
    var restoreFile: URL { folder.appending(path: "ProxyRestore.json") }
    var sessions: URL { folder.appending(path: "Sessions") }

    var arguments: [String] {
        func file(_ name: String) -> String { folder.appending(path: name).path }
        return [
            "--settings-file", file("Settings.json"), "--rules-file", file("Rules.json"),
            "--connections-file", file("Connections.json"), "--protobuf-file", file("Protobuf.json"),
            "--devices-file", file("Devices.json"), "--sessions-folder", sessions.path,
            "--crash-reports-folder", file("Crashes"), "--proxy-settings-stand-in", standIn.path,
            "--proxy-restore-file", restoreFile.path, "--root-stand-in", file("Root.dat"),
            "--root-file", file("Certificate.dat"), "--secrets-stand-in", file("Secrets.json"),
            "--allows-network-devices", "no", "--checks-for-updates", "no", "--has-seen-welcome", "yes",
            "--log-file", file("Reqly.log"),
        ]
    }
}

/// A copy of Reqly that a part starts, through GIO, which closes the self-check's descriptors in
/// it, and waits for without holding up the window.
@MainActor
private final class ChildRun {
    private let process: OpaquePointer
    /// Its process ID.
    let identifier: String

    init(_ arguments: [String]) throws {
        let launcher = g_subprocess_launcher_new(GSubprocessFlags(rawValue: 0))!
        defer { g_object_unref(raw(launcher)) }
        var error: UnsafeMutablePointer<GError>?
        let started = withCStrings([ProxyGuard.currentExecutable] + arguments) {
            g_subprocess_launcher_spawnv(launcher, $0, &error)
        }
        guard let started else { throw SelfCheck.Failure("Reqly didn't start: \(message(error))") }
        process = started
        identifier = string(g_subprocess_get_identifier(started)) ?? "?"
    }

    isolated deinit {
        g_object_unref(raw(process))
    }

    func send(_ signal: Int32) {
        g_subprocess_send_signal(process, signal)
    }

    /// Ends it, unless it has ended.
    func stop() {
        g_subprocess_force_exit(process)
    }

    /// Waits for it to end, and returns its exit status, or `nil` when a signal ended it.
    func wait() async -> Int32? {
        await withCheckedContinuation { done in
            let (callback, context) = whenReady { [process] _, result in
                _ = g_subprocess_wait_finish(process, result, nil)
                done.resume(
                    returning: g_subprocess_get_if_exited(process) != 0 ? g_subprocess_get_exit_status(process) : nil)
            }
            g_subprocess_wait_async(process, nil, callback, context)
        }
    }
}

/// TCP on 127.0.0.1, with plain sockets, so the app lookup sees this process's own connections.
private enum Loopback {
    struct Failed: Error, CustomStringConvertible {
        var step: String
        var description: String { "\(step) failed: \(String(cString: strerror(errno)))" }
    }

    /// A socket listening on 127.0.0.1, on `port`, or one the kernel picks, and the port.
    static func listen(port: Int = 0) throws -> (socket: Int32, port: Int) {
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard listener >= 0 else { throw Failed(step: "socket") }
        var address = loopback(port: port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Glibc.listen(listener, 8) == 0 else {
            close(listener)
            throw Failed(step: "listening on port \(port)")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        return (listener, Int(UInt16(bigEndian: address.sin_port)))
    }

    /// A connection to `port` on 127.0.0.1 that gives up reading after five seconds.
    static func connect(to port: Int) throws -> Int32 {
        let client = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard client >= 0 else { throw Failed(step: "socket") }
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(client)
            throw Failed(step: "connecting to port \(port)")
        }
        return client
    }

    static func write(_ text: String, to socket: Int32) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { send(socket, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            guard count > 0 else { return }
            offset += count
        }
    }

    /// What arrives on `socket` until `isWhole` says it's all there, the other end closes, or the
    /// time runs out.
    static func read(from socket: Int32, until isWhole: (String) -> Bool) -> String {
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isWhole(String(decoding: received, as: UTF8.self)) {
            let count = recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            received += buffer[..<count]
        }
        return String(decoding: received, as: UTF8.self)
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        return address
    }
}

/// A server on 127.0.0.1 that answers each request with "ok", one at a time, until it stops.
private final class OkServer: Sendable {
    private let listener: Int32
    let port: Int

    init() throws {
        (listener, port) = try Loopback.listen()
        Thread.detachNewThread { [listener] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                _ = Loopback.read(from: client) { $0.contains("\r\n\r\n") }
                Loopback.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok", to: client)
                close(client)
            }
        }
    }

    /// Stops accepting, which ends the server's thread.
    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }
}
