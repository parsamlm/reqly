#if DEBUG
    import AppKit
    import ApplicationServices
    import DeviceTools
    import Foundation
    import HAR
    import ReqlyModel
    import SwiftUI

    /// Launch arguments that walk through screens without clicking, in debug builds only. Each
    /// does what a menu item would, through the same code.
    enum DebugLaunch {
        private static var done: Set<String> = []

        /// Runs each time the live list changes, and acts once enough requests have arrived.
        static func trafficChanged(_ traffic: TrafficListModel, model: AppModel, openWindow: OpenWindowAction) {
            let defaults = UserDefaults.standard
            let count = traffic.all.count
            func once(_ key: String, after needed: Int, _ action: () -> Void) {
                guard needed > 0, count >= needed, !done.contains(key) else { return }
                done.insert(key)
                action()
            }
            if let place = Int(defaults.string(forKey: DefaultsKey.editRequest) ?? "") {
                once(DefaultsKey.editRequest, after: place) {
                    RequestActions(traffic: traffic, model: model, openWindow: openWindow)
                        .editAndResend(traffic.all[place - 1].id)
                }
            }
            let saveAt = defaults.integer(forKey: DefaultsKey.saveAt)
            if let path = defaults.string(forKey: DefaultsKey.saveSessionTo) {
                once(DefaultsKey.saveSessionTo, after: saveAt) {
                    Task { try? await traffic.saveSession(to: URL(filePath: path), hidingSecrets: false) }
                }
            }
            if let path = defaults.string(forKey: DefaultsKey.exportHARTo) {
                once(DefaultsKey.exportHARTo, after: saveAt) {
                    let ids = traffic.visible.map(\.id)
                    Task {
                        await traffic.settle()
                        let url = URL(filePath: path)
                        guard let writer = try? HARWriter(url: url, options: .init(), creatorVersion: "debug") else {
                            return
                        }
                        for id in ids {
                            if let exchange = await traffic.exchange(id) {
                                try? writer.append(exchange)
                            }
                        }
                        try? writer.finish()
                    }
                }
            }
            // Such as `-addRule block:3`.
            let addRule = (defaults.string(forKey: DefaultsKey.addRule) ?? "").split(separator: ":")
            if addRule.count == 2, let kind = RuleKind(rawValue: String(addRule[0])), let place = Int(addRule[1]) {
                once(DefaultsKey.addRule, after: place) {
                    RequestActions(traffic: traffic, model: model, openWindow: openWindow)
                        .addRule(kind, for: traffic.all[place - 1].id)
                }
            }
            if defaults.bool(forKey: DefaultsKey.showHARExport) {
                once(DefaultsKey.showHARExport, after: 1) {
                    traffic.harExport = HARExportRequest(selected: traffic.selection)
                }
            }
            // A moment later, so the last responses can finish first.
            once(DefaultsKey.stopCapturingAt, after: defaults.integer(forKey: DefaultsKey.stopCapturingAt)) {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await model.capture.stop()
                }
            }
            // Once the marker request arrives, and a moment later, so its response gets back first.
            if !done.contains(DefaultsKey.stopUsingReqlyOn),
                let marker = defaults.string(forKey: DefaultsKey.stopUsingReqlyOn),
                let serial = defaults.string(forKey: DefaultsKey.useReqlyOnEmulator),
                traffic.all.contains(where: { $0.target.hasPrefix(marker) })
            {
                once(DefaultsKey.stopUsingReqlyOn, after: 1) {
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        await stopUsingReqly(on: serial, model: model)
                    }
                }
            }
            let perfAt = defaults.string(forKey: DefaultsKey.perfAt) ?? ""
            for place in perfAt.split(separator: ",").compactMap({ Int($0) }) {
                once("\(DefaultsKey.perfAt):\(place)", after: place) {
                    PerfProbe.runSequence(at: place, traffic: traffic)
                }
            }
        }

        // MARK: - Simulators and emulators

        /// Presses Install Certificate for one simulator, as `-installCertificateOn "UDID|path"`
        /// asks, once it's running and HTTPS is set up, and writes how it went to the file. It
        /// acts only on that simulator, and only with a test certificate from `-rootFile`.
        static func installCertificate(_ spec: String, simulators: SimulatorsModel, https: HTTPSModel) async {
            let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let (udid, path) = (parts[0], parts[1])
            func report(_ text: String) {
                try? (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
            guard UserDefaults.standard.string(forKey: DefaultsKey.rootFile) != nil else {
                report("refused: needs -rootFile")
                return
            }
            var simulator: Simulator?
            let deadline = ContinuousClock.now + .seconds(60)
            while simulator == nil, ContinuousClock.now < deadline {
                if https.certificateForDevices != nil {
                    await simulators.refresh()
                    simulator = simulators.simulators.first { $0.id == udid }
                }
                if simulator == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            guard let certificate = https.certificateForDevices else {
                report("no certificate: \(https.status)")
                return
            }
            guard let simulator else {
                report("not running: \(udid) \(simulators.problem ?? "")")
                return
            }
            // What the Install Certificate button does.
            await simulators.installCertificate(on: simulator, certificate: certificate)
            switch simulators.installation(on: simulator, of: certificate) {
            case .installed: report("installed: \(https.certificateDetails?.name ?? "?") on \(simulator.name)")
            case .failed(let message): report("failed: \(message)")
            default: report("unknown")
            }
        }

        /// Presses Use Reqly and Copy Certificate for the emulators that `-useReqlyOnEmulator` and
        /// `-copyCertificateToEmulator` name, once capturing has started, the emulator is ready and,
        /// for the certificate, HTTPS is set up. Other emulators are left alone.
        static func driveEmulators(_ model: AppModel) async {
            let defaults = UserDefaults.standard
            guard !done.contains("driveEmulators") else { return }
            done.insert("driveEmulators")
            /// The port Reqly listens on, while it captures.
            var port: Int? {
                if case .capturing(let port) = model.capture.status { port } else { nil }
            }
            /// The emulator once it's ready and Reqly captures, within two minutes.
            func ready(_ serial: String, needsCertificate: Bool) async -> EmulatorsModel.Emulator? {
                for _ in 0..<120 {
                    await model.emulators.refresh()
                    if port != nil,
                        let emulator = model.emulators.emulators.first(where: { $0.id == serial && $0.isReady }),
                        !needsCertificate || model.https.certificateForDevices != nil
                    {
                        return emulator
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                reportEmulator(
                    "gave up on \(serial): capture \(model.capture.status), HTTPS \(model.https.status), "
                        + (model.emulators.problem ?? "\(model.emulators.emulators.map(\.id))"))
                return nil
            }
            if let serial = defaults.string(forKey: DefaultsKey.useReqlyOnEmulator),
                let emulator = await ready(serial, needsCertificate: false), let port
            {
                // What the Use Reqly button does.
                await model.emulators.setUsesReqly(true, emulator: emulator, port: port)
                let proxy = model.emulators.emulators.first { $0.id == serial }?.proxy
                reportEmulator(
                    proxy == EmulatorsModel.proxy(port: port)
                        ? "useReqly: \(serial) proxy \(proxy ?? "")"
                        : "useReqly failed: \(serial) \(model.emulators.notes[serial] ?? "proxy \(proxy ?? "none")")")
            }
            if let serial = defaults.string(forKey: DefaultsKey.copyCertificateToEmulator),
                let emulator = await ready(serial, needsCertificate: true),
                let certificate = model.https.certificateForDevices
            {
                // What the Copy Certificate button does.
                await model.emulators.copyCertificate(to: emulator, certificate: certificate)
                let name = model.https.certificateDetails?.name ?? "?"
                reportEmulator("copyCertificate: \(serial) \(name): \(model.emulators.notes[serial] ?? "")")
            }
        }

        /// What the Stop Using Reqly button does, for the `-useReqlyOnEmulator` emulator.
        private static func stopUsingReqly(on serial: String, model: AppModel) async {
            await model.emulators.refresh()
            guard let emulator = model.emulators.emulators.first(where: { $0.id == serial }),
                case .capturing(let port) = model.capture.status
            else {
                reportEmulator("stopUsingReqly failed: \(serial) isn't running, or Reqly isn't capturing")
                return
            }
            await model.emulators.setUsesReqly(false, emulator: emulator, port: port)
            let proxy = model.emulators.emulators.first { $0.id == serial }?.proxy
            reportEmulator(
                proxy == nil
                    ? "stopUsingReqly: \(serial) proxy none"
                    : "stopUsingReqly failed: \(serial) \(model.emulators.notes[serial] ?? "proxy \(proxy ?? "")")")
        }

        /// Adds a line to the `-emulatorResultFile` file.
        private static func reportEmulator(_ line: String) {
            guard let path = UserDefaults.standard.string(forKey: DefaultsKey.emulatorResultFile) else { return }
            let data = Data((line + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }

        /// Whether a composer window sends its request as soon as it opens.
        static var sendsComposed: Bool {
            UserDefaults.standard.bool(forKey: DefaultsKey.sendComposed)
        }

        /// Writes the menu bar as text: each menu's items with their shortcuts, separators and
        /// submenus, and whether each item is on, off, hidden, an alternate or has an image.
        static func dumpMenus(to path: String) {
            var lines: [String] = []
            func shortcut(_ item: NSMenuItem) -> String {
                guard !item.keyEquivalent.isEmpty else { return "" }
                let modifiers = item.keyEquivalentModifierMask
                let names: [(NSEvent.ModifierFlags, String)] = [
                    (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
                ]
                let keys = ["\r": "↩", "\u{8}": "⌫", "\t": "⇥", " ": "Space", "\u{1b}": "⎋"]
                let key = keys[item.keyEquivalent] ?? item.keyEquivalent.uppercased()
                return "  " + names.filter { modifiers.contains($0.0) }.map(\.1).joined() + key
            }
            func walk(_ menu: NSMenu, depth: Int) {
                // As if it were opening, since SwiftUI brings its menus up to date only then.
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.delegate?.menuWillOpen?(menu)
                defer { menu.delegate?.menuDidClose?(menu) }
                menu.update()
                let indent = String(repeating: "    ", count: depth)
                for item in menu.items {
                    if item.isSeparatorItem {
                        lines.append(indent + (item.isHidden ? "────── (hidden)" : "──────"))
                        continue
                    }
                    var notes: [String] = []
                    if item.isHidden { notes.append("hidden") }
                    if item.isAlternate { notes.append("alternate") }
                    if !item.isEnabled { notes.append("off") }
                    if item.state == .on { notes.append("checked") }
                    if item.image != nil { notes.append("image") }
                    let suffix = notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"
                    lines.append(indent + item.title + shortcut(item) + suffix)
                    if let submenu = item.submenu, depth < 3 {
                        walk(submenu, depth: depth + 1)
                    }
                }
            }
            for menu in NSApp.mainMenu?.items ?? [] {
                lines.append("■ " + (menu.submenu?.title ?? menu.title))
                if let submenu = menu.submenu {
                    walk(submenu, depth: 1)
                }
            }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }

        /// Writes what VoiceOver finds in every open window: the problems first (controls without a
        /// name, images without a description, and names that are symbol names), then each
        /// window's tree, cut short in long lists. It asks the accessibility API, as VoiceOver
        /// does, which works for an app's own windows without any permission.
        static func auditAccessibility(to path: String) {
            var problems: [String] = []
            var tree: [String] = []
            let named: Set<String> = [
                "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
                "AXSlider", "AXTextField", "AXComboBox", "AXIncrementor", "AXLink", "AXColorWell", "AXSearchField",
            ]
            // Parts of windows and scroll bars that VoiceOver names by their subrole.
            let windowButtons: Set<String> = [
                "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXIncrementArrow",
                "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage",
            ]
            let symbolName = /^[a-z0-9]+(\.[a-z0-9]+)+$/
            func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
            }
            func string(_ element: AXUIElement, _ name: String) -> String {
                switch attribute(element, name) {
                case let text as String: text
                case let number as NSNumber: number.stringValue
                default: ""
                }
            }
            func walk(_ element: AXUIElement, path: [String], depth: Int, budget: inout Int) {
                guard budget > 0, depth < 40 else { return }
                budget -= 1
                let role = string(element, kAXRoleAttribute)
                let subrole = string(element, kAXSubroleAttribute)
                let label = string(element, kAXDescriptionAttribute)
                let title = string(element, kAXTitleAttribute)
                let value = string(element, kAXValueAttribute)
                // A label next to a control can name it, as in a form's rows.
                let linked =
                    (attribute(element, kAXTitleUIElementAttribute)).map {
                        string($0 as! AXUIElement, kAXValueAttribute)
                    } ?? ""
                let name = !label.isEmpty ? label : !title.isEmpty ? title : linked
                let shown = [label, title == label ? "" : title, value].filter { !$0.isEmpty }
                    .map { "\"\($0.prefix(60))\"" }.joined(separator: " ")
                tree.append(String(repeating: "  ", count: min(depth, 30)) + role + " " + shown)
                let place = (path.suffix(3) + [role]).joined(separator: " › ")
                // A switch's or a slider's value is its state, not its name.
                let valueNames = !["AXCheckBox", "AXRadioButton", "AXSlider", "AXIncrementor"].contains(role)
                if named.contains(role), !windowButtons.contains(subrole), name.isEmpty,
                    !valueNames || value.isEmpty, string(element, "AXPlaceholderValue").isEmpty
                {
                    problems.append("unnamed \(role): \(place)")
                }
                let parts = name.components(separatedBy: ", ")
                if parts.count > 1, Set(parts).count < parts.count {
                    problems.append("name read twice, \"\(name)\": \(place)")
                }
                if !value.isEmpty, valueNames, name.hasSuffix(", \(value)") {
                    problems.append("value read twice, \"\(name)\" then \"\(value)\": \(place)")
                }
                if role == "AXImage", name.isEmpty {
                    problems.append("image without a description: \(place)")
                }
                if role != "AXLink", name.wholeMatch(of: symbolName) != nil {
                    problems.append("symbol name \"\(name)\" as the name: \(place)")
                }
                let here = name.isEmpty ? nil : "\(role) \"\(name.prefix(30))\""
                let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                // A long list shows its first rows, which stand for the rest.
                let isList = role == "AXTable" || role == "AXOutline" || role == "AXList"
                for child in isList ? children.prefix(8) : children[...] {
                    walk(child, path: here.map { path + [$0] } ?? path, depth: depth + 1, budget: &budget)
                }
            }
            let app = AXUIElementCreateApplication(getpid())
            for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                var budget = 6000
                let title = string(window, kAXTitleAttribute)
                tree.append("■ window \"\(title)\"")
                let before = problems.count
                walk(window, path: ["\"\(title)\""], depth: 0, budget: &budget)
                if budget <= 0 { tree.append("  (cut short)") }
                if problems.count == before { problems.append("✓ nothing to fix in \"\(title)\"") }
            }
            let report = ["Problems:"] + problems + ["", "Trees:"] + tree
            try? (report.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }

        /// Presses Tab through the window in front and writes what took the focus each time, until
        /// the focus comes back around or 80 presses have gone by.
        static func auditKeyboard(to path: String) async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            let app = AXUIElementCreateApplication(getpid())
            func focused() -> String {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                    let value
                else { return "nothing" }
                let element = value as! AXUIElement
                func string(_ name: String) -> String {
                    var text: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, name as CFString, &text)
                    return text as? String ?? ""
                }
                let name = [string(kAXDescriptionAttribute), string(kAXTitleAttribute)].first { !$0.isEmpty } ?? ""
                return "\(string(kAXRoleAttribute)) \"\(name.prefix(50))\""
            }
            func press(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) async {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: keyCode)
                    {
                        // A shortcut goes through the application, as a key press does.
                        if modifiers.contains(.command) {
                            NSApp.sendEvent(event)
                        } else {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            /// The detail pane's chosen section, as VoiceOver reads it.
            func section() -> String {
                func find(_ element: AXUIElement) -> String? {
                    var role: CFTypeRef?
                    var children: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                    if role as? String == "AXRadioButton" {
                        var value: CFTypeRef?
                        var title: CFTypeRef?
                        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &title)
                        if "\(value.map { $0 } ?? "" as CFTypeRef)" == "1" { return title as? String }
                    }
                    for child in children as? [AXUIElement] ?? [] {
                        if let found = find(child) { return found }
                    }
                    return nil
                }
                return find(app) ?? "none"
            }
            var lines = [
                "Full Keyboard Access: \(NSApp.isFullKeyboardAccessEnabled), active: \(NSApp.isActive)",
                "start: \(focused())",
            ]
            var seen: [String] = []
            for count in 1...80 {
                await press("\t", 48)
                let now = focused()
                lines.append("\(count): \(now)")
                if seen.first == now, seen.count > 2 { break }
                seen.append(now)
            }
            // From the request list, so the focus has somewhere to move.
            while !focused().hasPrefix("AXTable"), seen.count < 90 {
                await press("\t", 48)
                seen.append(focused())
            }
            lines.append("before ⌘F: \(focused())")
            await press("f", 3, .command)
            lines.append("⌘F: \(focused())")
            await press("\u{1b}", 53)
            lines.append("section before ⌘3: \(section())")
            await press("3", 20, .command)
            lines.append("⌘3: \(section())")
            await press("5", 23, .command)
            lines.append("⌘5: \(section())")
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
#endif
