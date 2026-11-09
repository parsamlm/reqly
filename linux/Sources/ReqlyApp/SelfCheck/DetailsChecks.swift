import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

extension SelfCheck {
    /// The details: each page's words, with the traffic maker's requests and the session the Mac
    /// saved; and the Timing page's waterfall.
    static let detailsParts: [Part] = [
        Part(name: "details", seconds: 240) { try await $0.checkDetails() },
        Part(name: "timing", seconds: 150) { try await $0.checkTiming() },
    ]

    /// Each page, for requests through Reqly's proxy from the traffic maker: one with a query,
    /// cookies both ways and a secret Authorization, whose headers show as dots until Show, and
    /// stay shown, whose cookies' values show with Show Values, and whose Raw page shows them with
    /// Show Them; Copy Headers and Copy Raw Request; a pin, a color and a comment, saved with
    /// Enter and on leaving the field, and removed, without reading the details again; the pages
    /// as screen readers have them, one Tab stop to a row; pictures of each page in light and
    /// dark; a failed one; an encrypted connection, whose note's button decrypts its host, and
    /// stops; and live ones, which the details follow, but not while the focus is in the page or
    /// the whole body is open. Then, in a copy of Reqly with the session the Mac saved, its
    /// decrypted, failed, blocked, gRPC and encrypted requests, and one from a phone. In that copy,
    /// this part checks only that.
    func checkDetails() async throws {
        if app.options.smokeSession != nil {
            try await checkTheMacsDetails()
            return
        }
        let session = try await session()
        let server = try TestServer()
        defer { server.stop() }
        _ = try await switchReady()
        try JSONEncoder().encode(Self.yourProxySettings).write(to: try standInFile())
        try await setCapture(on: true)
        do {
            let port = try present(model.listeningPort, "capturing has no port")
            let client = ProxyClient(proxyPort: port)
            try await checkARequestsPages(client, server: server, session: session)
            try await checkAFailedRequest(client, server: server, session: session)
            try await checkAnEncryptedConnection(proxyPort: port, server: server, session: session)
            try await checkALiveRequest(client, server: server, session: session)
        } catch {
            await putTheDetailsBack()
            try? await setCapture(on: false)
            throw error
        }
        await putTheDetailsBack()
        try await setCapture(on: false)

        let saved = try await runInCopy(
            ["details"], options: ["--smoke-session", Self.macSession().path, "--starts-capturing", "no"],
            seconds: 90)
        for line in saved where !line.hasSuffix("parts passed") {
            note("copy with the Mac's session: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    // MARK: - A request with everything

    private func checkARequestsPages(_ client: ProxyClient, server: TestServer, session: SessionHost) async throws {
        let details = window.details
        let sent = try await client.send(
            server.url(.cookies, "city=Tehran&days=3"),
            headers: [("Authorization", "Bearer self-check-token"), ("Cookie", "theme=light; session=abc123")])
        try require(sent.status == 200, "/cookies answered \(sent.status)")
        let id = try await finished("/cookies", on: server, session)
        try await open(id)

        let heading = words(in: details.heading)
        note("heading: \(heading.joined(separator: " | "))")
        for word in ["GET", "/cookies", "200", "127.0.0.1:\(server.port)"] {
            try require(heading.contains { $0.contains(word) }, "the heading doesn't say \(word): \(heading)")
        }
        let line = try present(heading.last, "the heading has no status line")
        try require(
            line.hasPrefix("OK · ") && line.contains(" ms · 17 B · "), "the status line says “\(line)”")

        let overview = try await pageWords(.overview)
        note("Overview: \(overview.joined(separator: " | "))")
        try requireAll(
            [
                "http://127.0.0.1:\(server.port)/cookies?city=Tehran&days=3", "Request", "Method", "GET", "Started",
                "Sent", "0 B", "Response", "Status", "200 OK", "Received", "17 B", "Content type", "application/json",
                "Duration", "Connection", "Protocol", "HTTP/1.1",
            ], in: overview, "Overview")
        try require(!overview.contains("None"), "Overview says None: \(overview)")
        try require(!overview.contains { $0.contains("decrypt") }, "Overview has a decryption note for plain HTTP")
        try require(
            !menuLabels().contains { $0.contains("Decrypt") }, "the details' menu for plain HTTP has \(menuLabels())")
        try require(gtk_widget_get_visible(details.commentSection) == 0, "the comment shows with no comment")

        // The request: its query, its headers, a secret as dots until Show, and its cookies.
        var request = try await pageWords(.request)
        note("Request: \(request.joined(separator: " | "))")
        try requireAll(
            [
                "Query parameters", "city", "Tehran", "days", "3", "Headers", "Host", "127.0.0.1:\(server.port)",
                "Authorization", "Cookie", "Cookies", "theme", "session", "Show Values", "Body",
                "This request has no body.",
            ], in: request, "Request")
        try require(!request.contains("Bearer self-check-token"), "the Authorization header shows before Show")
        try require(
            request.contains { $0.allSatisfy { $0 == "•" } && (8...16).contains($0.count) },
            "the secrets aren't 8 to 16 dots: \(request)")
        let page = try present(details.contents[.request], "the Request page has no box")
        let show = try present(button("Show", in: page), "the Authorization header has no Show")
        try requireOneTabStopEach(page, "Request")
        try await checkTheTreeOfRequest()
        emit(raw(show), "clicked")
        try await until("Show to show the Authorization header", seconds: 3) {
            self.words(in: page).contains("Bearer self-check-token")
        }
        // It stays shown on another page and back, and as Show Values builds the page again.
        try await pageWords(.raw)
        request = try await pageWords(.request)
        try require(request.contains("Bearer self-check-token"), "the Authorization header went back to dots")
        emit(raw(try present(button("Show Values", in: page), "the cookies have no Show Values")), "clicked")
        try await until("Show Values to show the cookies' values, with the token still shown", seconds: 3) {
            let shown = self.words(in: page)
            return shown.contains("light") && shown.contains("abc123") && shown.contains("Hide Values")
                && shown.contains("Bearer self-check-token")
        }
        note(
            "Request: Show shows Authorization's token, which stays shown; Show Values shows theme=light, session=abc123"
        )

        // Copy Headers copies them as they came, secrets and all, and says so in a toast, which
        // screen readers hear once.
        let copy = try present(iconButton("Copy Headers", in: page), "the headers have no Copy Headers")
        // GTK tells screen readers of an element only once they've read it, as Orca has.
        _ = try await AccessibilityTree.read(depth: 60, children: 60)
        let heard = try await AccessibilityTree.events(["object:announcement"], seconds: 4) {
            // The reader takes a moment to start listening.
            try? await Task.sleep(for: .milliseconds(1500))
            emit(raw(copy), "clicked")
            try? await Task.sleep(for: .milliseconds(1000))
        }
        let copied = copiedText() ?? ""
        try require(
            copied.contains("Authorization: Bearer self-check-token") && copied.contains("Host: 127.0.0.1"),
            "Copy Headers copied “\(copied)”")
        let toasts = toastWords()
        let said = heard.filter { $0.detail == "Copied" }.count
        try require(
            toasts.contains("Copied") && said == 1,
            "Copy Headers showed the toasts \(toasts), and screen readers heard “Copied” \(said) times")
        note("Copy Headers: a toast, “Copied”, which screen readers hear once")

        // The response: its cookies, with when they expire and their attributes, and its body.
        let response = try await pageWords(.response)
        note("Response: \(response.joined(separator: " | "))")
        // As the traffic maker's theme cookie says, in this computer's words for dates.
        let expires = DetailsFormat.day(Date(timeIntervalSince1970: 1_792_567_680))
        try requireAll(
            [
                "Headers", "Set-Cookie", "Content-Type", "application/json", "Cookies", "session", "theme",
                "Path / · Secure · HttpOnly", "Expires \(expires) · SameSite Lax", "Body",
            ], in: response, "Response")
        let body = try present(details.bodies[.response], "the Response page has no body view")
        let responsePage = try present(details.contents[.response], "the Response page has no box")
        try require(
            gtk_widget_is_ancestor(body.widget, responsePage) != 0, "the body's view isn't on the Response page")
        try requireOneTabStopEach(responsePage, "Response")

        // The Raw page: the secrets as dots, until Show Them.
        var rawWords = try await pageWords(.raw)
        try requireAll(
            ["Cookies and authorization headers are hidden.", "Show Them", "Request", "Response"], in: rawWords, "Raw")
        try require(
            rawWords.contains { $0.contains("GET /cookies?city=Tehran&days=3 HTTP/1.1\nHost: 127.0.0.1") }
                && rawWords.contains { $0.contains("Authorization: ••••••••\n") }, "the raw request is \(rawWords)")
        let rawPage = try present(details.contents[.raw], "the Raw page has no box")
        try await checkTheSecretsLine(rawPage)
        emit(raw(try present(button("Show Them", in: rawPage), "Raw has no Show Them")), "clicked")
        try await until("Show Them to show the secrets", seconds: 3) {
            self.words(in: rawPage).contains { $0.contains("Authorization: Bearer self-check-token") }
        }
        rawWords = words(in: rawPage)
        try require(rawWords.contains("Hide Them"), "Raw has no Hide Them once they show")
        let rawCopy = try present(iconButton("Copy Raw Request", in: rawPage), "Raw has no Copy Raw Request")
        emit(raw(rawCopy), "clicked")
        try require(
            copiedText()?.hasPrefix("GET /cookies?city=Tehran&days=3 HTTP/1.1\n") == true,
            "Copy Raw Request copied “\(copiedText() ?? "")”")
        emit(raw(try present(button("Hide Them", in: rawPage), "Raw has no Hide Them")), "clicked")
        try await until("Hide Them to hide the secrets", seconds: 3) {
            self.words(in: rawPage).contains { $0.contains("Authorization: ••••••••") }
        }
        note("Raw: the secrets as dots, then shown with Show Them, and hidden with Hide Them; copying works")

        let timing = try await pageWords(.timing)
        note("Timing: \(timing.joined(separator: " | "))")
        try requireAll(["Queued", "Connecting", "Waiting for server", "Downloading", "Total"], in: timing, "Timing")

        try await checkTheMarks(id, session: session)
        try await checkTheComment(id, session: session)
        try await checkATabsClick()
        try await takePictures("details")
    }

    /// A click on a tab chooses its page, and gives it the keyboard's focus.
    private func checkATabsClick() async throws {
        let details = window.details
        details.show(page: .overview)
        await settle()
        let tabs = descendants(of: details.switcher).filter {
            gtk_widget_get_focusable($0) != 0 && gtk_widget_get_mapped($0) != 0
        }
        let tab = try present(tabs.count == 5 ? tabs[2] : nil, "the tabs are \(tabs.map { typeName(raw($0)) })")
        let point = try FakeInput.click(tab)
        try await until("a click at \(point.x), \(point.y) to choose Response, its tab focused", seconds: 3) {
            details.page == .response && self.focus.map { self.window.isInside($0, tab) } ?? false
        }
        note("tabs: a click on Response chose it, and gave its tab the focus")
    }

    /// Pin, a color and none, from the details' actions, which the heading's buttons and the menu
    /// use: the session has them, the heading shows them, and the details aren't read again.
    private func checkTheMarks(_ id: ExchangeID, session: SessionHost) async throws {
        let details = window.details
        let reads = details.reads
        gtk_widget_activate_action_variant(details.widget, "details.pin", nil)
        try await untilTheSession("the pin to reach the session", seconds: 3) {
            await self.annotation(id, session).isPinned
        }
        try await until("the heading to show the pin", seconds: 3) {
            gtk_widget_has_css_class(details.headingView.pinButton, "accent") != 0
        }
        try require(menuLabels().contains("Unpin Request"), "the menu has no Unpin Request: \(menuLabels())")
        gtk_widget_activate_action_variant(details.widget, "details.color", g_variant_new_string("red"))
        try await untilTheSession("the red mark to reach the session", seconds: 3) {
            await self.annotation(id, session).color == .red
        }
        gtk_widget_activate_action_variant(details.widget, "details.color", g_variant_new_string("none"))
        gtk_widget_activate_action_variant(details.widget, "details.pin", nil)
        try await untilTheSession("the pin and the mark to go", seconds: 3) {
            let annotation = await self.annotation(id, session)
            return !annotation.isPinned && annotation.color == nil
        }
        await settle()
        try require(
            details.reads == reads, "pinning and marking read the details \(details.reads - reads) times again")
        note("marks: pinned, in the accent color, then red, then none and unpinned, without reading the details again")
    }

    /// Add Comment opens the comment, focused; Enter saves it, as does leaving the field, and an
    /// empty one removes it, with its section, and the Comment button has the focus.
    private func checkTheComment(_ id: ExchangeID, session: SessionHost) async throws {
        let details = window.details
        let field = details.commentField
        details.editComment()
        try await until("the comment field to have the focus", seconds: 3) {
            gtk_widget_get_mapped(field) != 0 && self.focus.map { self.window.isInside($0, field) } ?? false
        }
        gtk_editable_set_text(cast(field), "  Checked by the self-check  ")
        emit(raw(field), "activate")
        try await untilTheSession("Enter to save the comment", seconds: 3) {
            await self.annotation(id, session).comment == "Checked by the self-check"
        }
        try require(menuLabels().contains("Edit Comment…"), "the menu has no Edit Comment…: \(menuLabels())")
        gtk_editable_set_text(cast(field), "Saved on leaving")
        gtk_widget_grab_focus(details.headingView.pinButton)
        try await untilTheSession("leaving the field to save the comment", seconds: 3) {
            await self.annotation(id, session).comment == "Saved on leaving"
        }
        gtk_widget_grab_focus(field)
        gtk_editable_set_text(cast(field), "")
        emit(raw(field), "activate")
        try await untilTheSession("an empty comment to remove it", seconds: 3) {
            await self.annotation(id, session).comment == nil
        }
        await settle()
        try require(gtk_widget_get_visible(details.commentSection) == 0, "the comment still shows once it's gone")
        try require(
            focus == details.headingView.commentButton, "the Comment button doesn't have the focus once it's gone")
        note("comment: saved with Enter, trimmed, and on leaving the field; an empty one removes it")
    }

    // MARK: - A failed request

    private func checkAFailedRequest(_ client: ProxyClient, server: TestServer, session: SessionHost) async throws {
        _ = try await client.send(server.url(.fail))
        let id = try await finished("/fail", on: server, session)
        try await open(id)
        let overview = try await pageWords(.overview)
        let failure = "The server closed the connection before the response finished."
        try requireAll([failure, "Response", "No response yet."], in: overview, "a failed request's Overview")
        let box = try present(window.details.contents[.overview], "Overview has no box")
        let red = try present(label(failure, in: box), "the failure has no label")
        try require(gtk_widget_has_css_class(red, "error") != 0, "the failure isn't in red")
        let heading = words(in: window.details.heading)
        try require(heading.contains { $0.hasPrefix("Failed · ") }, "the failed one's heading says \(heading)")
        let response = try await pageWords(.response)
        try require(response == ["No response yet."], "a failed request's Response says \(response)")
        note("failed: “\(failure)” in red, “No response yet.”, and “\(heading.last ?? "")”")
        try await takePictures("details-failed", pages: [.overview])
    }

    // MARK: - An encrypted connection

    /// A tunnel through Reqly's proxy to the traffic maker: the note says it's encrypted, and its
    /// Decrypt button decrypts 127.0.0.1 from now on, after which it says so, and Stop Decrypting
    /// stops. The response can't be read; closed, the heading says so.
    private func checkAnEncryptedConnection(proxyPort: Int, server: TestServer, session: SessionHost) async throws {
        let https = model.https
        let host = "127.0.0.1"
        if https.decrypts(host) == true {
            await https.setDecrypts(false, host: host)
        }
        let tunnel = try await openTunnel(proxyPort: proxyPort, to: server)
        var isOpen = true
        defer {
            if isOpen {
                close(tunnel)
            }
        }
        let id = try await newest(session) { $0.kind == .tunnel && $0.port == server.port }
        try await open(id)
        let details = window.details
        try await until("the connection to be open", seconds: 5) { details.summary?.state == .open }
        let heading = words(in: details.heading)
        try requireSays(["CONNECT", "\(host):\(server.port)", "Encrypted connection"], in: heading, "its heading")
        try require(heading.contains { $0.hasPrefix("Open · ") }, "the open connection's heading says \(heading)")
        var overview = try await pageWords(.overview)
        try requireAll(
            [
                "This connection is encrypted, so Reqly can't show what's inside.", "Decrypt \(host)", "Connection",
                "HTTPS", "Encrypted, passed through untouched",
            ], in: overview, "the connection's Overview")
        try await takePictures("details-encrypted", pages: [.overview])
        let box = try present(details.contents[.overview], "Overview has no box")
        let decrypt = try present(button("Decrypt \(host)", in: box), "the note has no Decrypt")
        try require(gtk_widget_has_css_class(decrypt, "suggested-action") != 0, "Decrypt isn't the suggested action")
        emit(raw(decrypt), "clicked")
        try await until("Decrypt to decrypt \(host)", seconds: 5) {
            https.decrypts(host) == true && self.words(in: box).contains("Stop Decrypting \(host)")
        }
        overview = words(in: box)
        try require(
            overview.contains("Reqly now decrypts \(host). Its next requests show up decrypted."),
            "once decrypting, the note says \(overview)")
        try require(menuLabels().contains("Stop Decrypting \(host)"), "the menu has no Stop Decrypting \(host)")
        emit(raw(try present(button("Stop Decrypting \(host)", in: box), "the note has no Stop Decrypting")), "clicked")
        try await until("Stop Decrypting to stop", seconds: 5) {
            https.decrypts(host) == false && self.words(in: box).contains("Decrypt \(host)")
        }
        if let pattern = HostPattern(rawValue: host) {
            await https.removeHost(pattern)
        }
        note("encrypted: Decrypt \(host) decrypts it from now on, and the note says so; Stop Decrypting stops")

        let response = try await pageWords(.response)
        try require(
            response == ["Reqly doesn't decrypt this host, so the response isn't readable."],
            "the connection's Response says \(response)")
        let rawWords = try await pageWords(.raw)
        try require(rawWords.contains("Reqly doesn't decrypt this host."), "the connection's Raw says \(rawWords)")
        close(tunnel)
        isOpen = false
        try await until("the closed connection's heading", seconds: 5) {
            self.words(in: details.heading).contains { $0.hasPrefix("Closed · ") }
        }
        note("encrypted: its response isn't readable, and closed, its heading says “Closed”")
        try await checkAHostWithAnUnderscore(proxyPort: proxyPort, session: session)
    }

    /// A connection to a host with an underscore in its name, which the details' menu offers to
    /// decrypt with the name whole, though GTK reads an underscore as the next letter's shortcut.
    private func checkAHostWithAnUnderscore(proxyPort: Int, session: SessionHost) async throws {
        let host = "my_service.internal"
        // With no network, the host can't be found, and the connection fails.
        let answer = await onOwnThread { () -> String in
            guard let socket = try? Loopback.connect(to: proxyPort) else { return "" }
            defer { close(socket) }
            Loopback.write("CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n", to: socket)
            return Loopback.read(from: socket) { $0.contains("\r\n\r\n") }
        }
        let id = try await newest(session) { $0.kind == .tunnel && $0.host == host && $0.state.isFinished }
        try await open(id)
        let button = window.details.menuButton
        gtk_menu_button_popup(cast(button))
        defer { gtk_menu_button_popdown(cast(button)) }
        await settle()
        let popover = try present(gtk_menu_button_get_popover(cast(button)), "the details' menu has no popover")
        let entries = descendants(of: cast(popover)).filter { typeName(raw($0)) == "GtkModelButton" }.map { entry in
            descendants(of: entry).filter { typeName(raw($0)) == "GtkLabel" }
                .compactMap { string(gtk_label_get_text(cast($0))) }.joined()
        }
        // Decrypt, or Stop Decrypting where the parts before had Reqly decrypt every host.
        let entry = entries.first { $0 == "Decrypt \(host)" || $0 == "Stop Decrypting \(host)" }
        try require(
            entry != nil, "the details' menu for \(host), answered “\(answer.prefix(40))”, shows \(entries)")
        note("a host with an underscore: the details' menu shows “\(entry ?? "")”")
    }

    /// A CONNECT through Reqly's proxy to the traffic maker, which Reqly passes through, kept open:
    /// a request through it, and its answer.
    private func openTunnel(proxyPort: Int, to server: TestServer) async throws -> Int32 {
        let target = server.origin
        let result = await onOwnThread { () -> Result<Int32, Loopback.Failed> in
            guard let socket = try? Loopback.connect(to: proxyPort) else {
                return .failure(Loopback.Failed(step: "connecting to the proxy"))
            }
            Loopback.write("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n", to: socket)
            let answer = Loopback.read(from: socket) { $0.contains("\r\n\r\n") }
            guard answer.hasPrefix("HTTP/1.1 200") else {
                close(socket)
                return .failure(Loopback.Failed(step: "the CONNECT, answered “\(answer.prefix(40))”,"))
            }
            Loopback.write("GET /ok HTTP/1.1\r\nHost: \(target)\r\n\r\n", to: socket)
            let ok = Loopback.read(from: socket) { $0.hasSuffix("ok") }
            guard ok.hasSuffix("ok") else {
                close(socket)
                return .failure(Loopback.Failed(step: "the request through the connection"))
            }
            return .success(socket)
        }
        return try result.get()
    }

    // MARK: - A live request

    /// A slow request, chosen while it waits: the details say it's in progress, then follow it to
    /// its end, reading the details again.
    private func checkALiveRequest(_ client: ProxyClient, server: TestServer, session: SessionHost) async throws {
        let details = window.details
        let slow = Task { try await client.send(server.url(.slow, "ms=2000")) }
        let id = try await newest(session) { $0.path == "/slow" && $0.port == server.port && !$0.state.isFinished }
        try await open(id)
        try await until("the details to read the waiting request", seconds: 3) { details.summary != nil }
        let reads = details.reads
        let waiting = words(in: details.heading)
        try require(waiting.contains { $0.hasPrefix("In progress") }, "the waiting request's heading says \(waiting)")
        let timing = try await pageWords(.timing)
        try require(timing.contains("In progress"), "the waiting request's Timing says \(timing)")
        _ = try await slow.value
        try await until("the details to follow the request to its end", seconds: 5) {
            details.summary?.state == .completed && self.words(in: details.heading).contains("200")
        }
        let done = try await pageWords(.timing)
        try require(!done.contains("In progress"), "the finished request's Timing still says In progress")
        try require(details.reads > reads, "the details weren't read again as the request finished")
        note("live: “\(waiting.last ?? "")”, then “\(words(in: details.heading).last ?? "")”, read again")
        try await checkAHiddenLiveRequest(client, server: server, session: session)
        try await checkALiveRequestsFocus(client, server: server, session: session)
        try await checkAGrowingWholeBody(client, server: server, session: session)
    }

    /// A response that comes a piece at a time, chosen as it comes: while the keyboard's focus is
    /// in the Overview, the page waits as its Received grows, so the widget with the focus stays,
    /// rather than going for one screen readers would say again at each piece; once the focus
    /// leaves, the page follows the request again.
    private func checkALiveRequestsFocus(_ client: ProxyClient, server: TestServer, session: SessionHost) async throws {
        let details = window.details
        let drip = Task { try await client.send(server.url(.drip, "pieces=60&gap=200")) }
        let id = try await newest(session) { $0.path == "/drip" && $0.port == server.port && !$0.state.isFinished }
        try await open(id)
        try await pageWords(.overview)
        let box = try present(details.contents[.overview], "Overview has no box")
        let stay = try present(DetailsPane.focusables(in: box).first, "Overview has nothing that takes the focus")
        g_object_ref(raw(stay))
        defer { g_object_unref(raw(stay)) }
        gtk_widget_grab_focus(stay)
        try await until("the Overview's first value to have the focus", seconds: 3) { self.focusWidget == stay }
        let received = details.details?.exchange.bytesReceived ?? 0
        try await until("the details to read more of the response as it comes", seconds: 5) {
            (details.details?.exchange.bytesReceived ?? 0) > received && details.summary?.state.isFinished == false
        }
        await settle()
        try require(details.summary?.state.isFinished == false, "the response ended before the check")
        try require(
            focusWidget == stay && gtk_widget_is_ancestor(stay, box) != 0,
            "the Overview was built again as the response came, and the \(focusType) has the focus")
        try require(details.focusTab(), "the details' tab doesn't take the focus")
        try await until("the Overview to be built again once the focus left it", seconds: 3) {
            gtk_widget_is_ancestor(stay, box) == 0
        }
        note("live, the focus in the Overview: the page waits as \(Format.size(received)) grows, then follows")
        _ = try await drip.value
        try await until("the details to follow the response to its end", seconds: 5) {
            details.summary?.state == .completed
        }
    }

    /// A response too big to show inline that's still coming: its whole body, opened, stays open as
    /// it grows, and the body that grew meanwhile shows once you close it.
    private func checkAGrowingWholeBody(_ client: ProxyClient, server: TestServer, session: SessionHost) async throws {
        let details = window.details
        let drip = Task { try await client.send(server.url(.drip, "pieces=500&gap=20")) }
        let id = try await newest(session) { $0.path == "/drip" && $0.port == server.port && !$0.state.isFinished }
        try await open(id)
        try await pageWords(.response)
        let view = try present(details.bodies[.response], "the Response page has no body")
        try await until("Show Whole Body for the response as it comes", seconds: 10) {
            gtk_widget_get_mapped(view.showWhole) != 0 && details.summary?.state.isFinished == false
        }
        emit(raw(view.showWhole), "clicked")
        try await until("the whole body", seconds: 10) { view.whole?.code.isFilled == true }
        let size = view.body?.body.wireSize ?? 0
        try await until("the details to read more of the response", seconds: 5) {
            (details.details?.exchange.bytesReceived ?? 0) > Int64(size) && view.waiting != nil
        }
        try require(view.whole != nil, "Show Whole Body closed as the response grew")
        view.whole?.close()
        try await until("the body that grew to show once Show Whole Body closed", seconds: 5) {
            view.whole == nil && view.waiting == nil && (view.body?.body.wireSize ?? 0) > size
        }
        note("live, its whole body open: it stays open as \(Format.size(Int64(size))) grows, then the grown body shows")
        _ = try await drip.value
    }

    /// A slow request, chosen while it waits, then hidden by a search that finds nothing, so no
    /// row changes as it ends: the details follow it to its end all the same.
    private func checkAHiddenLiveRequest(_ client: ProxyClient, server: TestServer, session: SessionHost) async throws {
        let details = window.details
        let list = window.list
        let search = window.search
        let slow = Task { try await client.send(server.url(.slow, "ms=1500&hidden")) }
        let id = try await newest(session) { $0.path == "/slow" && $0.port == server.port && !$0.state.isFinished }
        try await open(id)
        try await until("the details to read the waiting request", seconds: 3) { details.summary != nil }
        search.open()
        defer { search.close() }
        gtk_editable_set_text(cast(search.entry), "zzqx")
        try await until("the search to find nothing", seconds: 5) {
            search.query == "zzqx" && list.count == 0 && list.isSettled
        }
        try require(
            details.shown == id && details.summary?.state.isFinished == false,
            "the hidden request isn't shown in progress")
        _ = try await slow.value
        try await until("the details to follow the hidden request to its end", seconds: 5) {
            details.summary?.state == .completed && self.words(in: details.heading).contains("200")
        }
        note("live and hidden by a search: the details follow it to “\(words(in: details.heading).last ?? "")”")
    }

    // MARK: - The Mac's session

    /// In a copy of Reqly with the Mac's session: its pages' words for the decrypted forecast,
    /// with its comment, pin, color, query, secret Authorization and Set-Cookie; the failed and the
    /// blocked ones; the gRPC call; the encrypted connection; the one Reqly sent itself; and the
    /// phone's.
    private func checkTheMacsDetails() async throws {
        _ = try await session()
        try await until("the saved session's rows", seconds: 10) { window.list.count >= 16 }
        await settle()
        let details = window.details

        try await open(ExchangeID(rawValue: 1))
        let heading = words(in: details.heading)
        try requireAll(["GET", "/v2/forecast", "200", "api.weatherly.dev · Weatherly"], in: heading, "heading")
        try require(heading.contains { $0.hasPrefix("OK · 750 ms · ") }, "the forecast's status line says \(heading)")
        try require(gtk_widget_has_css_class(details.headingView.pinButton, "accent") != 0, "the pin isn't accented")
        var overview = try await pageWords(.overview)
        note("forecast's Overview: \(overview.joined(separator: " | "))")
        try requireAll(
            [
                "Comment", "Looks right", "Reqly decrypted this request.",
                "https://api.weatherly.dev/v2/forecast?city=Lisbon&days=3", "App", "Weatherly", "Bundle ID",
                "dev.weatherly.app", "Status", "200 OK", "Duration", "750 ms", "To the server", "HTTP/2", "HTTPS",
                "Decrypted by Reqly",
            ], in: overview, "the forecast's Overview")
        try require(!overview.contains("None"), "the forecast's Overview says None")
        try require(
            !overview.contains("Decrypt api.weatherly.dev") && !overview.contains("Stop Decrypting api.weatherly.dev"),
            "a saved session's note has a button")
        let request = try await pageWords(.request)
        try requireAll(
            ["Query parameters", "city", "Lisbon", "days", "3", "Accept", "Authorization", "Show"], in: request,
            "the forecast's Request")
        try require(!request.contains("Bearer secret-token"), "the forecast's token shows before Show")
        let response = try await pageWords(.response)
        try requireAll(["Set-Cookie", "Cookies", "session", "Show Values", "Body"], in: response, "the response")
        try require(!response.contains("secret-cookie"), "the forecast's cookie shows before Show Values")
        let rawWords = try await pageWords(.raw)
        try require(
            rawWords.contains { $0.contains("Authorization: ••••••••") && $0.hasPrefix("GET /v2/forecast") },
            "the forecast's raw request is \(rawWords)")
        note("forecast: decrypted, commented, pinned, its secrets hidden")

        try await open(ExchangeID(rawValue: 7))
        overview = try await pageWords(.overview)
        try requireAll(
            ["Couldn't connect to the server: The name weather.invalid didn't resolve.", "No response yet."],
            in: overview, "the unreachable one's Overview")
        try await open(ExchangeID(rawValue: 8))
        overview = try await pageWords(.overview)
        try requireAll(
            [
                "The rule “No ads” blocked this request, so Reqly closed the connection.", "Rules", "No ads",
                "Closed the connection.",
            ], in: overview, "the blocked one's Overview")
        note("failed: couldn't connect, and blocked by “No ads”")

        try await open(ExchangeID(rawValue: 6))
        overview = try await pageWords(.overview)
        try requireAll(
            [
                "This connection is encrypted, so Reqly can't show what's inside.",
                "Encrypted, passed through untouched",
                "48.1 KB", "3.50 s",
            ], in: overview, "the encrypted connection's Overview")
        let tunnelHeading = words(in: details.heading)
        try requireAll(
            ["CONNECT", "maps.weatherly.dev", "Encrypted connection · Weatherly"], in: tunnelHeading, "its heading")
        try require(tunnelHeading.contains { $0.hasPrefix("Closed · 3.50 s · 48.1 KB") }, "it says \(tunnelHeading)")
        let tunnelResponse = try await pageWords(.response)
        try require(
            tunnelResponse == ["Reqly doesn't decrypt this host, so the response isn't readable."],
            "the encrypted connection's Response says \(tunnelResponse)")
        note("encrypted: “Encrypted, passed through untouched”, its response unreadable")

        try await open(ExchangeID(rawValue: 12))
        overview = try await pageWords(.overview)
        try requireAll(["gRPC status", "0 OK"], in: overview, "the gRPC call's Overview")
        try require(words(in: details.heading).contains { $0.contains("gRPC OK") }, "the gRPC call's heading")
        let trailers = try await pageWords(.response)
        try requireAll(["Trailers", "grpc-status", "0"], in: trailers, "the gRPC call's Response")

        try await open(ExchangeID(rawValue: 16))
        overview = try await pageWords(.overview)
        try requireAll(
            [
                "Sent over TLS by Reqly", "Reverse proxy", "The app sent it to localhost:8080", "Upstream proxy",
                "proxy.example.com:8080", "Client certificate", "Reqly Test Client",
            ], in: overview, "the composed one's Overview")
        try await requireValuesInLine(.overview, "the composed one's Overview")

        try await open(ExchangeID(rawValue: 13))
        overview = try await pageWords(.overview)
        try requireAll(["Device", "Parsa's iPhone · 192.168.1.23"], in: overview, "the phone's Overview")
        try require(
            words(in: details.heading).contains("api.weatherly.dev · Parsa's iPhone"), "the phone's heading")
        try await open(ExchangeID(rawValue: 11))
        try require(words(in: details.heading).contains { $0.contains("3 messages") }, "the WebSocket's heading")
        note("gRPC, trailers, Reqly's own with its proxies and certificate, a phone's, and a WebSocket's")
    }

    // MARK: - The Timing page

    /// The waterfall: in a copy with the Mac's session, the forecast's steps, in the accent color
    /// for the server's time and half of it for the transfer, with tenths of a millisecond under
    /// 10 ms and the total; the blocked request's last step in red; a reused connection's three
    /// steps; and an encrypted connection with none. Here, a live request's "In progress" and an
    /// open connection's "Still open".
    func checkTiming() async throws {
        if app.options.smokeSession != nil {
            try await checkTheMacsTiming()
            return
        }
        let session = try await session()
        let server = try TestServer()
        defer { server.stop() }
        _ = try await switchReady()
        try JSONEncoder().encode(Self.yourProxySettings).write(to: try standInFile())
        try await setCapture(on: true)
        do {
            let port = try present(model.listeningPort, "capturing has no port")
            if model.https.decrypts("127.0.0.1") == true {
                await model.https.setDecrypts(false, host: "127.0.0.1")
            }
            let tunnel = try await openTunnel(proxyPort: port, to: server)
            defer { close(tunnel) }
            let open = try await newest(session) { $0.kind == .tunnel && $0.port == server.port }
            try await self.open(open)
            try await until("the connection to be open", seconds: 5) { self.window.details.summary?.state == .open }
            let timing = try await pageWords(.timing)
            try requireAll(["Queued", "Connecting", "Total", "Still open"], in: timing, "an open connection's Timing")
            try require(!timing.contains("DNS lookup"), "an address needs no DNS lookup: \(timing)")
            note("open connection: \(timing.joined(separator: " | "))")

            let client = ProxyClient(proxyPort: port)
            let slow = Task { try await client.send(server.url(.slow, "ms=1500")) }
            let id = try await newest(session) { $0.path == "/slow" && $0.port == server.port && !$0.state.isFinished }
            try await self.open(id)
            let waiting = try await pageWords(.timing)
            try require(waiting.contains("In progress"), "a waiting request's Timing says \(waiting)")
            _ = try await slow.value
            try await until("the Timing page to follow the request", seconds: 5) {
                self.window.details.summary?.state == .completed
                    && !self.words(in: self.timingBox).contains("In progress")
            }
            let total = words(in: timingBox).drop { $0 != "Total" }.dropFirst().first ?? ""
            note("live: “In progress”, then a total of \(total)")
        } catch {
            await putTheDetailsBack()
            try? await setCapture(on: false)
            throw error
        }
        await putTheDetailsBack()
        try await setCapture(on: false)

        let saved = try await runInCopy(
            ["timing"], options: ["--smoke-session", Self.macSession().path, "--starts-capturing", "no"],
            seconds: 90)
        for line in saved where !line.hasSuffix("parts passed") {
            note("copy with the Mac's session: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    private var timingBox: Widget { window.details.contents[.timing] ?? window.details.widget }

    private func checkTheMacsTiming() async throws {
        _ = try await session()
        try await until("the saved session's rows", seconds: 10) { window.list.count >= 16 }
        await settle()
        try await open(ExchangeID(rawValue: 1))
        let forecast = try await pageWords(.timing)
        note("forecast: \(forecast.joined(separator: " | "))")
        try requireAll(
            [
                "Queued", "2.0 ms", "DNS lookup", "Connecting", "TLS handshake", "125 ms",
                "Request sent", "0.0 ms", "Waiting for server", "250 ms", "Downloading", "Total", "750 ms",
                "Connection", "Protocol", "HTTP/1.1", "To the server", "HTTP/2", "Remote address", "203.0.113.24:443",
                "TLS", "1.3", "Reused connection", "No",
            ], in: forecast, "the forecast's Timing")
        try await requireValuesInLine(.timing, "the forecast's Timing")
        let looks = bars().map(look)
        try require(
            looks == ["dim", "dim", "dim", "dim", "dim", "accent", "half-accent"],
            "the forecast's bars are \(looks)")
        try await takePictures("timing", pages: [.timing])

        try await open(ExchangeID(rawValue: 8))
        let blocked = try await pageWords(.timing)
        try require(
            blocked.first == "The rule “No ads” blocked this request, so Reqly closed the connection.",
            "the blocked one's Timing starts \(blocked.first ?? "")")
        try require(bars().last.map(look) == "failed", "the blocked one's last step isn't red")
        try await open(ExchangeID(rawValue: 16))
        let reused = try await pageWords(.timing)
        try requireAll(
            ["Request sent", "Waiting for server", "Downloading", "Reused connection", "Yes"], in: reused,
            "the reused one's Timing")
        try require(!reused.contains("Queued") && bars().count == 3, "a reused connection has \(bars().count) steps")
        try await open(ExchangeID(rawValue: 6))
        let tunnel = try await pageWords(.timing)
        try require(
            tunnel == ["Connection", "HTTPS", "Encrypted, passed through untouched"],
            "the encrypted connection's Timing says \(tunnel)")
        note(
            "blocked: its last step red; reused: 3 steps; encrypted: no steps, \(tunnel.suffix(2).joined(separator: " "))"
        )
    }

    /// The Timing page's bars, in order.
    private func bars() -> [Widget] {
        descendants(of: timingBox).filter { typeName(raw($0)) == "GtkDrawingArea" }
    }

    private func look(_ bar: Widget) -> String {
        ["accent", "half-accent", "failed"].first { gtk_widget_has_css_class(bar, $0) != 0 } ?? "dim"
    }

    // MARK: - Screen readers and the keyboard

    /// The Request page as screen readers have it: its scroller named, each header's value
    /// named by its header, and the secret's Show button and its dots.
    private func checkTheTreeOfRequest() async throws {
        await settle()
        let tree = try await AccessibilityTree.read(depth: 60, children: 60)
        let scroller = tree.nodes.first { $0.role == "scroll pane" && $0.name == "Request" }
        let panes = tree.nodes.filter { $0.role == "scroll pane" }.map { $0.line.trimmingCharacters(in: .whitespaces) }
        try require(scroller != nil, "no scroller is named Request: \(panes)")
        let host = tree.nodes.first { $0.relations["labelled-by"] == ["Host"] }
        try require(host?.name == "Host", "the Host header's value isn't named by its header: \(host?.line ?? "none")")
        let show = tree.nodes.first { $0.name == "Show Authorization" }
        try require(show != nil, "no button is named Show Authorization")
        try require(tree.nodes.contains { $0.role == "label" && $0.name == "Hidden" }, "no secret is called Hidden")
        let heading = tree.nodes.first { $0.name == "GET /cookies" }
        note(
            "screen readers: the scroller “Request”, \(host?.line.trimmingCharacters(in: .whitespaces) ?? ""), "
                + "\(show?.line.trimmingCharacters(in: .whitespaces) ?? ""), the path “\(heading?.name ?? "")”")
        try require(heading != nil, "the heading's path isn't named with its method")
    }

    /// The Raw page's line about its secrets is on one line, with Show Them right after it, once
    /// the page is wide enough for both, at 1000 pixels, with the details over the list.
    private func checkTheSecretsLine(_ page: Widget) async throws {
        let window = window
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(cast(window.window), &width, &height)
        let showsContent = adw_navigation_split_view_get_show_content(window.inner)
        gtk_window_set_default_size(cast(window.window), 1000, height)
        try await until("the window to be 1000 pixels wide", seconds: 5) { gtk_widget_get_width(window.window) <= 1000 }
        window.openDetails()
        try await until("the details over the list", seconds: 5) { window.detailsAreOver }
        await settle()
        let shown = window.details.shown
        defer {
            // Back as it was, showing the same request.
            adw_navigation_split_view_set_show_content(window.inner, showsContent)
            gtk_window_set_default_size(cast(window.window), width, height)
        }
        let text = "Cookies and authorization headers are hidden."
        let label = try present(
            descendants(of: page).first {
                typeName(raw($0)) == "GtkLabel" && string(gtk_label_get_text(cast($0))) == text
            },
            "Raw has no line about its secrets")
        let lines = pango_layout_get_line_count(gtk_label_get_layout(cast(label)))
        try require(
            lines == 1,
            "with the Raw page \(gtk_widget_get_width(page)) px wide, the line about its secrets takes \(lines) lines")
        note("Raw at 1000 px: the line about its secrets on one line, Show Them after it")
        // The heading lines up with the cards under it, at both sides.
        let overview = try present(window.details.pages[.overview], "Overview has no box")
        try await pageWords(.overview)
        await settle()
        let card = try present(
            descendants(of: overview).first { gtk_widget_has_css_class($0, "card") != 0 }, "Overview has no card")
        let heading = window.details.headingView
        let edges = [heading.method, heading.commentButton, card].map { widget in
            var bounds = graphene_rect_t()
            _ = gtk_widget_compute_bounds(widget, window.window, &bounds)
            return (Int(bounds.origin.x.rounded()), Int((bounds.origin.x + bounds.size.width).rounded()))
        }
        try require(
            abs(edges[0].0 - edges[2].0) <= 1 && abs(edges[1].1 - edges[2].1) <= 1,
            "the heading runs from \(edges[0].0) to \(edges[1].1) px, "
                + "and the cards from \(edges[2].0) to \(edges[2].1)")
        note("at 1000 px, the heading lines up with the cards, from \(edges[2].0) to \(edges[2].1) px")
        adw_navigation_split_view_set_show_content(window.inner, showsContent)
        gtk_window_set_default_size(cast(window.window), width, height)
        // GTK keeps the window on the screen, inside the shadow's margin.
        try await until("the window back to its size", seconds: 5) {
            let now = gtk_widget_get_width(window.window)
            return now <= width && now > width - 20 && window.details.shown == shown
        }
        await settle()
    }

    /// Each of a page's rows is one Tab stop: its value, or a secret's Show. A cookie's row has
    /// none while its value is hidden, as there's nothing in it to read.
    private func requireOneTabStopEach(_ page: Widget, _ name: String) throws {
        let rows = descendants(of: page).filter { gtk_widget_has_css_class($0, "details-row") != 0 }
        let stops = rows.map { row in
            (DetailsPane.focusables(in: row).count, gtk_widget_has_css_class(row, "details-cookie") != 0)
        }
        let wrong = stops.filter { $0.0 != 1 && !($0.1 && $0.0 == 0) }
        try require(!rows.isEmpty && wrong.isEmpty, "\(name)'s rows have \(stops.map(\.0)) Tab stops each")
        note("\(name): \(rows.count) rows, one Tab stop each, but for cookies whose values are hidden")
    }

    /// A page's values all start at one place, beside names long and short, as on the Mac.
    private func requireValuesInLine(_ page: DetailsPane.Page, _ name: String) async throws {
        let box = try present(window.details.contents[page], "\(name) has no box")
        await settle()
        let rows = descendants(of: box).filter {
            gtk_widget_has_css_class($0, "details-row") != 0
                && gtk_orientable_get_orientation(cast($0)) == GTK_ORIENTATION_HORIZONTAL
        }
        var starts: [String: Int] = [:]
        // Each name's width and lines, and its least and natural widths, for when they don't line up.
        var names: [String] = []
        for row in rows {
            guard let title = gtk_widget_get_first_child(row), let value = gtk_widget_get_next_sibling(title) else {
                continue
            }
            var bounds = graphene_rect_t()
            _ = gtk_widget_compute_bounds(value, window.window, &bounds)
            let words = string(gtk_label_get_text(cast(title))) ?? ""
            starts[words] = Int(bounds.origin.x.rounded())
            var least: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_measure(title, GTK_ORIENTATION_HORIZONTAL, -1, &least, &natural, nil, nil)
            let lines = pango_layout_get_line_count(gtk_label_get_layout(cast(title)))
            names.append("\(words) \(gtk_widget_get_width(title)) px, \(lines) lines, \(least)-\(natural)")
        }
        try require(
            !starts.isEmpty && Set(starts.values).count == 1,
            "\(name)'s values start at \(starts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }); "
                + "names: \(names)")
        note("\(name): \(starts.count) values start at \(starts.values.first ?? 0) px")
    }

    // MARK: - Pictures

    /// Pictures of `pages` in light and dark, as they show now.
    private func takePictures(_ name: String, pages: [DetailsPane.Page] = DetailsPane.Page.allCases) async throws {
        let manager = adw_style_manager_get_default()
        let scheme = adw_style_manager_get_color_scheme(manager)
        defer { adw_style_manager_set_color_scheme(manager, scheme) }
        var taken: [String] = []
        for (style, forced) in [("light", ADW_COLOR_SCHEME_FORCE_LIGHT), ("dark", ADW_COLOR_SCHEME_FORCE_DARK)] {
            adw_style_manager_set_color_scheme(manager, forced)
            for page in pages {
                _ = try await pageWords(page)
                await settle()
                let file = try picture("\(name)-\(page.rawValue)-\(style).png")
                let size = try await ownPicture(window.window, to: file)
                taken.append("\(file.lastPathComponent) (\(size))")
            }
        }
        note("pictures: \(taken.joined(separator: ", "))")
    }

    // MARK: - Helpers

    /// Selects `id`'s row and shows the details over the list, once they've read it.
    private func open(_ id: ExchangeID) async throws {
        let details = window.details
        window.list.select(id: id)
        try await until("the details to show request #\(id.rawValue)", seconds: 5) {
            details.shown == id && details.details?.exchange.id == id
        }
        window.openDetails()
        try await until("the details to show over the list", seconds: 5) { gtk_widget_get_mapped(details.widget) != 0 }
    }

    /// `page`, once it's built for the request shown, and its words.
    @discardableResult
    private func pageWords(_ page: DetailsPane.Page) async throws -> [String] {
        let details = window.details
        details.show(page: page)
        try await until("the \(page.title) page", seconds: 5) { details.isBuilt(page) }
        return words(in: try present(details.pages[page], "\(page.title) has no box"))
    }

    /// The newest finished request to `path` on the traffic maker.
    private func finished(_ path: String, on server: TestServer, _ session: SessionHost) async throws -> ExchangeID {
        try await newest(session) { $0.path == path && $0.port == server.port && $0.state.isFinished }
    }

    /// The newest request `matches` takes, once there is one.
    private func newest(_ session: SessionHost, _ matches: (ExchangeSummary) -> Bool) async throws -> ExchangeID {
        let deadline = monotonicMicroseconds() + 10_000_000
        repeat {
            let ids = await session.rowIDs().ids.suffix(40)
            if let summary = await session.rows(Array(ids)).last(where: matches) {
                return summary.id
            }
            try await Task.sleep(for: .milliseconds(50))
        } while monotonicMicroseconds() < deadline
        throw Failure("the request's row didn't come")
    }

    /// Waits until `condition`, which asks the session, holds, looking every 20 ms, for at most
    /// `seconds`.
    private func untilTheSession(_ what: String, seconds: Int, _ condition: () async -> Bool) async throws {
        let deadline = monotonicMicroseconds() + seconds * 1_000_000
        while await !condition() {
            guard monotonicMicroseconds() < deadline, !Task.isCancelled else {
                throw Failure("gave up waiting for \(what)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func annotation(_ id: ExchangeID, _ session: SessionHost) async -> Annotation {
        await session.rows([id]).first?.annotation ?? Annotation()
    }

    /// The details' menu's entries, its submenu's and sections' included.
    private func menuLabels() -> [String] {
        var labels: [String] = []
        func read(_ menu: UnsafeMutablePointer<GMenuModel>) {
            for item in 0..<g_menu_model_get_n_items(menu) {
                if let value = g_menu_model_get_item_attribute_value(menu, item, "label", nil) {
                    labels.append(string(g_variant_get_string(value, nil)) ?? "")
                    g_variant_unref(value)
                }
                for link in ["section", "submenu"] {
                    if let linked = g_menu_model_get_item_link(menu, item, link) {
                        read(linked)
                        g_object_unref(raw(linked))
                    }
                }
            }
        }
        read(cast(window.details.menu))
        return labels
    }

    /// Every word `root` and what's in it show: labels, text fields and text views, in order.
    private func words(in root: Widget) -> [String] {
        var found: [String] = []
        var child = gtk_widget_get_first_child(root)
        while let widget = child {
            if gtk_widget_get_visible(widget) != 0 {
                switch typeName(raw(widget)) {
                case "GtkLabel":
                    if let text = string(gtk_label_get_text(cast(widget))), !text.isEmpty {
                        found.append(text)
                    }
                case "GtkText":
                    found.append(string(gtk_editable_get_text(cast(widget))) ?? "")
                case "GtkTextView":
                    let buffer = gtk_text_view_get_buffer(cast(widget))
                    var start = GtkTextIter()
                    var end = GtkTextIter()
                    gtk_text_buffer_get_bounds(buffer, &start, &end)
                    found.append(takeString(gtk_text_buffer_get_text(buffer, &start, &end, 0)) ?? "")
                default:
                    found += words(in: widget)
                }
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return found
    }

    private func requireAll(_ wanted: [String], in words: [String], _ what: String) throws {
        let missing = wanted.filter { !words.contains($0) }
        try require(
            missing.isEmpty, "\(what) doesn't say \(missing.map { "“\($0)”" }.joined(separator: ", ")): \(words)")
    }

    /// Each of `wanted` is in one of `words`.
    private func requireSays(_ wanted: [String], in words: [String], _ what: String) throws {
        let missing = wanted.filter { piece in !words.contains { $0.contains(piece) } }
        try require(
            missing.isEmpty, "\(what) doesn't say \(missing.map { "“\($0)”" }.joined(separator: ", ")): \(words)")
    }

    /// The widgets under `root`, depth first.
    /// The words of the toasts that show in the window.
    private func toastWords() -> [String] {
        descendants(of: window.window).filter { typeName(raw($0)) == "AdwToastWidget" }
            .flatMap { descendants(of: $0) }.filter { typeName(raw($0)) == "GtkLabel" }
            .compactMap { string(gtk_label_get_text(cast($0))) }
    }

    private func descendants(of root: Widget) -> [Widget] {
        var found: [Widget] = []
        var child = gtk_widget_get_first_child(root)
        while let widget = child {
            found.append(widget)
            found += descendants(of: widget)
            child = gtk_widget_get_next_sibling(widget)
        }
        return found
    }

    /// The button with `label` under `root`.
    private func button(_ label: String, in root: Widget) -> Widget? {
        descendants(of: root).first {
            gtk_widget_get_visible($0) != 0 && typeName(raw($0)) == "GtkButton"
                && string(gtk_button_get_label(cast($0))) == label
        }
    }

    /// The icon button with `name` for screen readers under `root`, by its tooltip, which says the
    /// same.
    private func iconButton(_ name: String, in root: Widget) -> Widget? {
        descendants(of: root).first {
            typeName(raw($0)) == "GtkButton" && string(gtk_widget_get_tooltip_text($0)) == name
        }
    }

    /// The label saying `text` under `root`.
    private func label(_ text: String, in root: Widget) -> Widget? {
        descendants(of: root).first {
            typeName(raw($0)) == "GtkLabel" && string(gtk_label_get_text(cast($0))) == text
        }
    }

    /// What has the window's focus.
    private var focus: Widget? {
        gtk_root_get_focus(cast(window.window))
    }

    /// The text Reqly last put on the clipboard.
    private func copiedText() -> String? {
        guard let display = gdk_display_get_default(),
            let content = gdk_clipboard_get_content(gdk_display_get_clipboard(display))
        else { return nil }
        var value = GValue()
        g_value_init(&value, g_type_from_name("gchararray"))
        defer { g_value_unset(&value) }
        guard gdk_content_provider_get_value(content, &value, nil) != 0 else { return nil }
        return string(g_value_get_string(&value))
    }

    /// The details back beside the list, on Overview, with nothing selected.
    private func putTheDetailsBack() async {
        adw_navigation_split_view_set_show_content(window.inner, 0)
        window.list.select(id: nil)
        window.details.show(page: .overview)
        await settle()
    }
}
