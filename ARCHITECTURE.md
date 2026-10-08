# Reqly architecture

This document explains how Reqly is built: the Mac app today, the core it will share with the Windows app, and the phone companion apps that send traffic to them. It covers:

- the stack
- the processes
- the code map
- how traffic flows
- the rules that keep Reqly fast and safe
- how the code is shared across platforms

What Reqly does is in the [roadmap](ROADMAP.md). How it looks is in the [design guidelines](design/GUIDELINES.md).

To change one of these choices, open a pull request that explains why.

## At a glance

| | |
|---|---|
| Language | Swift 6, with complete data-race checking |
| Interface | SwiftUI, with AppKit for the request list and the code and hex viewers |
| Platform | macOS 26 and later. Windows in Phase 2; companion apps for iPhone, iPad and Android in Phases 3 and 4 |
| Proxy engine | SwiftNIO: NIOHTTP1, NIOHTTP2 and NIOSSL |
| Certificates | swift-certificates and swift-crypto; the root key lives in the Keychain |
| Storage | SQLite, through GRDB |
| Scripts | JavaScript, run by QuickJS-ng, which is built into Reqly |
| System proxy | ReqlyHelper, a small privileged helper that switches the proxy and always restores it |
| Code organization | ReqlyKit, a Swift package with no UI code, plus the app, whose screens use `@Observable` models |
| Tests | Swift Testing |
| Updates | Sparkle, in copies built with the public half of the key that signs updates. Other copies check GitHub Releases once a day and link to the download |
| Crash reports | Never sent automatically; after a crash, Reqly offers a prefilled GitHub issue |
| Distribution | Signed with Developer ID and notarized; on GitHub Releases and Homebrew |

Why these:

- **Swift everywhere.** One language covers everything from the proxy engine to the screens. Swift also runs on Windows, so the Windows app shares the core. Most people who use Reqly are Apple developers and can already read it.
- **SwiftNIO.** It is Apple's networking library for server-side Swift. It already has the HTTP/1.1, HTTP/2 and TLS pieces a proxy needs.
- **AppKit only where SwiftUI would struggle.** That means a list with 100,000 live rows, and text views holding megabytes of text.
- **Plain `@Observable` models.** Contributors don't have to learn an architecture framework to read the app.

## Processes

```
  Apps on your Mac              Reqly.app (runs as you)                  Servers
 ┌─────────────────┐  proxy     ┌─────────────────────────────┐  direct  ┌─────────┐
 │ Safari, Mail,   │──────────▶ │ ProxyEngine (SwiftNIO)      │────────▶ │ api.…   │
 │ your own app…   │ 127.0.0.1  │ CertificateAuthority        │          │ cdn.…   │
 └─────────────────┘   :9090    │ Capture ▸ TrafficStore      │          └─────────┘
                                │ SwiftUI + AppKit interface  │
                                └──────────────┬──────────────┘
                                               │ XPC
                                ┌──────────────▼──────────────┐
                                │ ReqlyHelper (root, launchd) │
                                │ sets the system proxy and   │
                                │ always restores it          │
                                └─────────────────────────────┘
```

**Reqly.app** runs as you.
- It holds the interface, the proxy engine, the certificate authority and the traffic store.
- The proxy listens on 127.0.0.1 only, so other computers can't use it, until you turn on devices on your Wi-Fi. Then it also listens on the Mac's network address, and asks you before it accepts a new device.

**ReqlyHelper** is a launchd daemon inside the app bundle, registered with `SMAppService`. You approve it once in System Settings.
- It is the only code that changes network settings.
- It does two things: it points the HTTP and HTTPS proxy of every active network service at Reqly, and it puts the previous settings back.
- It restores them:
  - when you stop capturing
  - when Reqly quits or crashes (it watches Reqly's process)
  - when the Mac starts up after a capture was left on, for example after a power cut

**Why a helper?** Changing network settings needs administrator rights. Without a helper:
- Reqly would ask for your password every time.
- Nothing could restore the settings after a crash, and the roadmap rules that out.

**Details that keep it reliable:**
- The helper saves the settings to a file in a folder only root can open, before it changes anything.
- It exits after a quiet minute. launchd starts it again when Reqly asks, or at startup.
- If the registered helper belongs to a copy of Reqly that has moved or been deleted, or that another team signed, Reqly registers its own helper and tries again. macOS won't start a helper whose team differs from the one it was registered with, and keeps the request waiting, so Reqly waits at most ten seconds for an answer.
- Remove Helper…, in Settings › General, takes the helper out of macOS. Reqly asks for approval again the next time it's needed.

**Without the helper,** Reqly captures only apps that are pointed at it by hand, and says so in the status line. This happens in builds that aren't signed by a team, since the helper only trusts a Reqly signed by its own team, and with the launch argument `-setsSystemProxy NO`.

**Later,** a network extension could capture apps that ignore the system proxy. It would feed the same engine.

## Code map

```
Reqly.app          SwiftUI + AppKit, @Observable models
    │
Capture            starts and stops capturing, records traffic
    │
ProxyEngine · TrafficStore · SourceResolver · SystemProxy · Keychain · HAR · DeviceTools
    │
CertificateAuthority · BodyKit · Scripts · HelperProtocol
    │
ReqlyModel         shared value types
```

Each layer uses only the layers below it. Everything below Reqly.app lives in two packages: ReqlyKit, in `core/`, which the Windows app will share, and ReqlyMacKit, in `mac/ReqlyMacKit/`, for the modules marked Mac only. ReqlyHelper is a separate small program. It uses HelperCore, which holds its logic so that tests can reach it.

| Module | What it does | Uses |
|---|---|---|
| ReqlyModel | Value types shared by everything: exchanges, headers, timings, sources, rules | — |
| BodyKit | Decompresses bodies, detects content types, builds JSON trees, highlights syntax, parses form data, formats hex, reads protobuf messages, `.proto` files and gRPC's framing | zlib (through CZlib); Compression for Brotli, on the Mac |
| CertificateAuthority | Creates the root certificate, and issues and caches the certificates for decrypted hosts. `RootStore` is where the root is kept and trusted | swift-certificates, swift-crypto |
| Keychain | Mac only. `CertificateStore`, the `RootStore` that keeps the root in the login keychain and asks macOS to trust it | CertificateAuthority, Security |
| HelperProtocol | The XPC interface between the app and ReqlyHelper, and the code-signing checks both sides use | Security |
| HelperCore | ReqlyHelper's work: saves the proxy settings, points them at Reqly, puts them back, and watches Reqly's process | HelperProtocol, SystemConfiguration |
| ProxyEngine | The proxy: HTTP/1.1 and HTTP/2, CONNECT tunnels, decryption, connections to servers, interceptors | ReqlyModel, CertificateAuthority, SwiftNIO |
| TrafficStore | Saves and queries traffic: batched writes, filters, search, bodies, size limits | ReqlyModel, BodyKit, GRDB |
| SourceResolver | Finds which app or tool opened each connection, and the simulator or emulator it runs in, from the Mac's process table; and the hardware addresses of devices on the network | ReqlyModel |
| SystemProxy | Registers ReqlyHelper and asks it to set or restore the proxy, as the model's `SystemProxySwitch` | HelperProtocol, ReqlyModel |
| HAR | Imports and exports HAR files, and makes cURL commands | ReqlyModel, BodyKit |
| DeviceTools | Lists running simulators and installs Reqly's certificate in them with Xcode's `simctl`; points Android emulators at Reqly with `adb` | — |
| Scripts | Runs your JavaScript on matching requests and responses, each run in a sandbox with a time limit | ReqlyModel, CQuickJS |
| CQuickJS | QuickJS-ng, the JavaScript engine, built from its amalgamation without its standard library | — |
| Capture | Runs the engine, switches the proxy through a `SystemProxySwitch`, credits connections to apps and devices, records into the store, and keeps the rules | the modules above, except HAR and the Mac-only ones: SourceResolver, SystemProxy, Keychain and DeviceTools |

Most of these modules will also build for Windows. [Other platforms](#other-platforms) says which, and what still has to change.

### The app

- **Scenes:**
  - the main window, for the traffic being captured
  - a window for each session or HAR file you open, laid out like the main window, without the controls for capturing
  - a composer window for each request you write or edit, with its response beside it
  - the Rules window, with every kind of rule and its switch
  - the Devices window, for setting up phones, tablets, simulators and emulators
  - Reqly Help, from the Help menu: the version, the website, the source code and the license, whose text the app carries
    - Open Source Licenses, next to the license, lists the open-source packages inside the app, with each one's license and notices in full. They come from `Resources/Acknowledgements.json`, which `tools/acknowledgements.py` writes from the packages' checkouts. License texts the checkouts don't include, such as BoringSSL's own LICENSE, are kept in `tools/licenses`.
  - Settings: General (the proxy port, starting, the menu-bar item, the helper, updates), HTTPS (the certificate and the hosts to decrypt), the upstream proxy, reverse proxies, client certificates and `.proto` files
  - the menu-bar item, a panel with the capture switch, the traffic so far, the toolbar's other switches (breakpoints and slow network), and the way to decryption, devices and Settings
  - the welcome window, which opens the first time Reqly does and from the Help menu
  - the crash report window, after a crash
- **AppModel** creates the services once at launch and hands them to the feature models. Views get their models from the environment.
- **Menus** act on the window in front: each window publishes its traffic as a focused value, so Save Session, Export as HAR and the Request menu reach the right one.
  - Each window opens from the menu its work belongs to: Devices from Capture, Rules from Rules, Reqly Help and the welcome window from Help. Their scenes' commands are removed, so the Window menu lists only Reqly (⌘0), which `WindowCommands` adds back.
  - Save Session and Export as HAR replace the File menu's export group. Replacing the Save group would remove Close, and a window group's own Save group drops anything added to it.
  - A request's own menu has the Request menu's groups, in its order.
  - SwiftUI brings menu items up to date with the window in front when a menu opens, not when a shortcut is pressed. So before AppKit looks for a ⌘-shortcut, an event monitor in `AppDelegate` brings the menus up to date, as opening them would; without it, a shortcut such as ⇧⌘C could find its item still disabled.
  - Find… (⌘F) opens a text editor's find bar when one has the focus, and otherwise puts the focus in the window's request search. View › Overview to Messages (⌘1 to ⌘6) switch the detail pane's section, for the keyboard alone.
- **Features** get one folder each: Capture, HTTPS, Sidebar, TrafficList, Inspector, Rules, Compose, Devices, Connections, Protobuf, Sessions, Welcome, Settings, MenuBar, Updates, CrashReports, Help.
  - Each folder has its views and a `@MainActor @Observable` model.
  - Views stay thin: they show the model's state and call its methods.
  - Models reach ReqlyKit through protocols, so tests can use fakes.
- **AppKit views** are wrapped for SwiftUI:
  - `RequestTableView`, an `NSTableView`
  - `CodeView`, an `NSTextView` with TextKit 2
  - `HexView`, which draws only the visible rows
- **Resources** follow the guidelines:
  - Colors and the icon come from the asset catalog.
  - Strings come from a String Catalog, English first.
  - Every custom AppKit view works with VoiceOver and the keyboard.

### Concurrency

- Swift 6 language mode with complete checking.
- The app target isolates code to the main actor by default. ReqlyKit modules are nonisolated and pass `Sendable` values between threads.
- The engine runs on SwiftNIO event loops, one per CPU core.
- TrafficStore writes on a single writer and reads concurrently, using SQLite's WAL mode.
- The interface runs on the main actor.

## How a request travels

1. **Connect.** An app sends its request to 127.0.0.1:9090, because the system proxy points there. While the request goes on its way, SourceResolver finds which app opened the connection:
   - It looks through the Mac's process table for the process holding the connection's other end. Lookups that arrive together share one pass, which takes a few milliseconds.
   - A helper app inside another app, such as one of Chrome's, is credited to the app that holds it.
   - An XPC service, such as the one Safari uses for networking, is credited to the app that macOS holds responsible for it.
   - A command-line tool, such as curl, is credited by its own name, even when it ships inside an app, as Xcode's git does.
   - Processes of other users, such as system daemons that run as root, can't be read, so their traffic shows no app.
   - The connection's exchanges are credited once the answer arrives, and its later exchanges right away.
   - Devices on your Wi-Fi connect to the Mac's network address instead. [Devices](#devices) says how they're let in and labeled.
2. **Plain HTTP.** The request carries the full URL and goes straight on to the server.
3. **HTTPS.** The app first asks for a tunnel with `CONNECT host:443`.
   - **The host isn't on your decrypt list:** Reqly relays the encrypted bytes untouched and records an encrypted connection with its host, size and duration.
   - **The host is on the list:** Reqly completes the TLS handshake itself, using a certificate for that host from CertificateAuthority. ALPN picks HTTP/2 or HTTP/1.1. Each request, including each HTTP/2 stream, becomes one exchange.
4. **To the server.** The engine opens its own connection to the server.
   - The connection goes direct, never through the system proxy, so Reqly can't loop into itself. With an upstream proxy, it goes through that one instead; [Connections](#connections) says how.
   - TLS to the server is always verified against the Mac's trust store.
   - Reqly offers HTTPS servers HTTP/2 and HTTP/1.1, and ALPN lets the server choose, whichever one the app speaks with Reqly. Plain HTTP, and requests that switch protocols, such as WebSocket upgrades, go over HTTP/1.1.
   - Connections are pooled per server on each event loop, so both sides of an exchange stay on one thread. An HTTP/2 connection carries many requests at once, each on a stream of its own. HTTP/1.1 connections carry one request at a time and are reused when it's done.
     - While the first connection to a server opens, the requests behind it wait to see whether they can share it. A server that chose HTTP/1.1 is remembered, so later requests don't wait.
     - A connection leaves the pool when it closes, or when the server says it's going away.
   - Trailers, the headers that come after a body, go on to the app and are recorded, because a gRPC call's status is in them.
   - Every step is timed for the Timing tab: the DNS lookup, connecting, the TLS handshake, sending the request, waiting for the server and the download.
     - NIO's own resolver doesn't say when a lookup finished, so the engine brings its own. It calls `getaddrinfo` just as NIO's does, and keeps Happy Eyeballs.
     - Each exchange also records the server's address, the TLS version, and whether it reused an open connection.
5. **Rules.** Each rule matches a host, a path and a method, where `*` matches anything, and each kind of rule has a switch of its own. When a request's head arrives, the engine works out once what the rules do to it. The first matching rule of each kind acts, except Rewrite, where every matching rule makes its changes. Each rule can let the exchange through, change it, hold it until you decide, or answer it itself:
   - **Block** and **Map Local** answer once the request has all arrived, and the server never sees it. A Block rule wins over Map Local. A host that isn't decrypted shows no paths, so only a Block rule for the whole host stops its tunnel.
   - **Map Remote** sends the request to another server. What the app asked for stays on record.
   - **Rewrite** changes headers, the query and the status as they pass. Changing body text needs the whole message, so it's held until it has all arrived. Reqly asks the server not to compress a response it changes, and unpacks it if the server does anyway.
   - **Breakpoints** hold the whole request or response and wait for you. The engine reports it paused, the detail pane edits it, and the edited message goes on, or the exchange fails as cancelled. If the app gives up while it waits, the exchange fails too.
   - **Slow network** goes first on each connection to a server, next to the socket, so it slows the TLS handshake too. Bytes wait half the latency each way, and opening a connection takes a round trip. A speed limit lets bytes through a tick at a time, and each lost packet holds the connection up for a round trip. When the server closes, the close waits for the bytes still on their way.
     - A connection to a server is reused only over the same network. When a change slows a host down differently, its tunnels that aren't decrypted close, so apps reconnect.
   - Each rule that acts is recorded with the exchange, and the Overview lists them, including what you changed at a breakpoint.
   - Requests you send yourself, by resending or composing, go through the rules like any other.
   - **Scripts** run on the whole request after Rewrite rules, and on the whole response before breakpoints, so a breakpoint shows what a script did. Every script that matches runs, in the order of the list. [Scripts](#scripts) says how.
6. **Recording.** The engine emits events: headers arrived, body bytes, finished, failed. Capture assembles the events into exchanges and passes body bytes straight on. TrafficStore writes them in batches, and the interface picks up the changes.
7. **Everything else.**
   - After a WebSocket upgrade, the connection becomes a tunnel that relays bytes untouched. The engine reads copies of them in each direction, puts the frames back together into messages, unpacks the ones compressed with permessage-deflate, and records each message with its direction and time.
   - Other protocols inside a tunnel are relayed byte for byte.
   - If an app rejects Reqly's certificate, for example because it pins certificates, Reqly flags the host and suggests you stop decrypting it.

## Keeping it fast

The roadmap asks for a smooth app at 10,000 requests. Tests use 100,000.

- The main thread never touches the network, the database or a whole body.
- TrafficStore writes events in one transaction about every 100 ms.
- The request list:
  - takes changes at most ten times a second
  - keeps only row summaries in memory: status, method, host, path, app, time, duration and size
  - filters those summaries on every change; each one's kind of content is worked out once, when it's made, so filtering 100,000 rows stays well under the time of a frame
- Details and bodies load on demand, off the main thread.
- Bodies are written to disk as they arrive.
- Bodies are unpacked, recognized and formatted in the background.
  - JSON and XML are formatted, and forms read, up to 8 MB. Coloring stops at 1 MB.
  - Text views show the first 16 MB and lay out only what is on screen. The hex view draws only the rows on screen.
  - JSON nested deeper than 100 levels is shown as text. Parsing it would exhaust a background thread's small stack.

## Storing traffic

TrafficStore keeps each session on disk, so a long session doesn't fill the memory. Only exchanges in progress, and ones that finished in the last few seconds, stay in memory.

**Where it lives.** Each session is a folder in `~/Library/Application Support/Reqly/Sessions/`, which only you can open. The folder holds:
- `traffic.sqlite`, a SQLite database with tables for exchanges, the apps and tools that sent them, bodies, and a search index
- your pins, colors and comments, in columns of the exchange table that saving traffic never writes, so a save that's on its way can't undo them
- a `bodies` folder, with a file for each body too big for the database

**Saving.** About ten times a second, Capture saves everything that changed in one transaction. Only then does the interface hear about it, so every row it shows can already be read from the store.
- If saving fails, for example because the disk is full, Capture tries again every second. The window's subtitle says why traffic isn't being saved.

**Bodies** are kept exactly as they came over the wire.
- A body up to 256 KB stays in the database. A bigger one moves to its own file.
- Reqly keeps up to 64 MB of each body. Bytes past that still count toward the exchange's size.
- Bodies are decoded (gzip, deflate, Brotli) only to show, search or export them.

**Search** uses an FTS5 trigram index, which finds any text of three characters or more, ignoring case. Comments are matched in memory instead, since they're short and change often.
- It covers the URL, the request and status lines, every header, and the first 1 MB of each body's text.
- A body goes in once its exchange finishes, unpacked. Images and other binary types stay out, and so do compressed bodies over 8 MB.
- The index keeps no copy of the text it indexes.
- Searching for one or two characters matches URLs and methods only.

**How long it's kept.**
- A session lasts until you quit Reqly. Then its folder is deleted, unless you saved the session.
- Clearing deletes every exchange except the pinned ones, along with their bodies and search entries.
- While a Reqly runs, it holds a lock on its session folder. At launch, Reqly deletes every session folder that no running Reqly holds: those were left behind by a crash.
- Save Session turns the same database into a single file you can keep and share. The format is the same on the Mac and Windows, so either app can open it.
  - The file is a snapshot of the database, taken while capturing goes on, with the bodies that had files of their own moved inside it. SQLite's application ID marks it as Reqly's: `RQLY`.
  - It has no search index, which keeps it smaller. Opening the file builds one.
  - Saving can hide authorization headers and cookies.
  - Opening a session, or a HAR file, makes a copy in a session folder of its own, shown in a window of its own. The file itself never changes. A file saved by a newer Reqly, with changes this one doesn't know, is refused.

**Size limit.** A session keeps the latest 100,000 exchanges. Past that, the oldest finished ones go first, except pinned ones.

**WebSocket messages** have a table of their own (storage migration "v8: websocket messages"), numbered in order for each exchange, and deleted with it. Reqly keeps up to 1 MB of each message.

**How it got there.** Each exchange records the upstream proxy it went through, the reverse proxy the app sent it to, and the client certificate Reqly presented, by name (storage migration "v10: proxies"). What scripts printed is kept with it, too (storage migration "v11: script output"). So is whether Reqly sent the request itself, from the composer or Resend (storage migration "v12: sent by Reqly"). The detail pane says "Decrypted by Reqly" only for an app's HTTPS that didn't come through a reverse proxy, whichever app sent it. HAR files keep the client certificate, the reverse proxy and the requests Reqly sent, in the custom fields `_clientCertificate`, `_reverseProxy` and `_sentByReqly`.

**Settings.** The traffic rules are saved as JSON in `~/Library/Application Support/Reqly/Rules.json`, where Capture's `RulesFile` writes them.
- The file has a version number. A file from a newer Reqly is left alone: this Reqly doesn't use its rules or write over it. One that can't be read is set aside as `Rules (unreadable).json`, so nothing is lost.
- Rules apply to the exchanges that start after a change.
- The `.proto` files you add are saved as a list of paths in `Protobuf.json`, beside the rules, with the message types you chose for bodies. The files themselves stay where they are, and are read again at each launch.
- The upstream proxy, the reverse proxies and the client certificates are saved in `Connections.json`, beside the rules. Their secrets aren't: the proxy's password, and each certificate with its private key, are generic password items in the login keychain, "Reqly Upstream Proxy" and "Reqly Client Certificate". A debug build takes `-connectionsFile` and `-secretsFile` paths instead, so trying things out leaves your settings and Keychain alone.
- Scripts are rules, saved in `Rules.json` with their code. The file's version is 2 since scripts came; a Reqly from before them leaves it alone. The hosts to decrypt, and other simple preferences, use `UserDefaults`.

## Certificates and HTTPS

**The root certificate** is created on your Mac the first time you set up HTTPS.
- It has an ECDSA P-256 key and is a self-signed CA certificate named "Reqly CA" and the minute it was made, such as "Reqly CA 2026-10-04 00:10". A device keeps the certificate it was given, so after a new one is made, each device needs it installed again; the name tells the two apart.
- The private key stays in the Keychain.

**Trust.** Reqly asks macOS to trust the certificate for your user account only, which needs your password. Settings › HTTPS shows its status. It can also remove the certificate, its trust setting and its key in one step, along with any Reqly certificates an earlier version left in the keychain.

**Which hosts are decrypted.** Settings › HTTPS keeps a list of hosts, such as `api.weatherly.dev` or `*.weatherly.dev`, each with a switch.
- When more than one entry matches a host, the most specific one decides: an exact host before a wildcard, and a longer wildcard before a shorter one. So `api.weatherly.dev` switched off stays encrypted while `*.weatherly.dev` is on.
- Decrypt all hosts covers every host that no entry switches off. It's off unless you turn it on, since some apps stop working when their traffic is decrypted.
- Stop Decrypting in a request's menu switches its host off, or adds it switched off, so a wildcard or Decrypt all hosts leaves it alone.
- A change closes the tunnels it affects, so apps reconnect the new way.

**Certificates for decrypted hosts.** For each host, Reqly issues a certificate signed by the root, following Apple's requirements for TLS server certificates. It keeps these in memory while it runs.

**Servers.** Connections to servers are always verified. If a server's certificate is invalid, the request fails and Reqly shows why.

## Rules we keep

- Captured traffic stays on the Mac.
  - Reqly has no analytics.
  - It connects to the internet only to relay traffic and to check for updates.
- Reqly never lowers the security of a connection to a server.
- Devices on your Wi-Fi can use Reqly only after you allow each one.
- Only ReqlyHelper changes system settings, and only the proxy settings.
  - It accepts connections only from Reqly signed by the same team.
  - It offers a handful of commands and checks every argument.
- Private macOS functions are used only where there's no public one, and only with a fallback. They're looked up when Reqly runs, so a macOS without them still runs Reqly. Today there's one:
  - `responsibility_get_pid_responsible_for_pid` finds the app an XPC service works for. Without it, the service is credited by its own name.
- ReqlyKit never imports SwiftUI or AppKit.
- The main thread never waits on the network or the disk.
- Secrets such as authorization headers and cookies are masked in the interface until you choose to show them. HAR export warns about them.
- New dependencies need a reason in the pull request.
  - The list: swift-nio, swift-nio-ssl, swift-nio-http2, swift-certificates and swift-crypto from Apple, plus GRDB and QuickJS-ng. Sparkle belongs to the Mac app alone, so the Xcode project resolves it and ReqlyKit doesn't.
  - After adding or updating one, run `tools/acknowledgements.py`, so the app shows its license. The script stops at a package it doesn't know, to have someone check what that package's license asks for.

## Crash reports

- macOS saves a report for every crash in `~/Library/Logs/DiagnosticReports`.
- When Reqly launches, it looks for reports about itself, by its bundle identifier, and about ReqlyHelper, which macOS keeps in `/Library/Logs/DiagnosticReports` since it runs as root, written since it last launched. The first launch ever skips the ones from before. If it finds one, a window says Reqly quit unexpectedly and shows what the issue would say, with Report on GitHub….
  - That opens a new issue in the browser, prefilled with the Reqly and macOS versions, the exception, and the crashed thread's frames, cut short to fit in a link.
  - It leaves out what could say who you are: paths in your home folder, and the Mac's identifiers. macOS already hides the paths in a report's own fields.
  - You read and edit the issue before you submit it. Show in Finder shows the full report, to attach.
- Nothing is sent automatically.
- Help › Report a Problem… opens a new issue with the versions filled in, for problems that aren't crashes.
- ReqlyHelper restores the system proxy no matter how Reqly ends.

## Project layout

Each platform has a folder of its own, beside the code and the design they share.

```
Reqly/
├── core/                   ReqlyKit, the Swift package the Mac and Windows apps share:
│                           Sources/<Module>, Tests/<Module>Tests
├── mac/                    Reqly for Mac
│   ├── Reqly.xcodeproj
│   ├── Reqly/              the app
│   │   ├── App/            ReqlyApp, AppModel, scenes
│   │   ├── Features/       Capture, HTTPS, Sidebar, TrafficList, Inspector,
│   │   │                   Rules, Compose, Devices, Connections, Protobuf,
│   │   │                   Sessions, Welcome, Settings, MenuBar, Updates,
│   │   │                   CrashReports, Help
│   │   ├── AppKit/         RequestTableView, CodeView, HexView
│   │   └── Resources/      asset catalog, Reqly.icon, Localizable.xcstrings,
│   │                       Acknowledgements.json
│   ├── ReqlyHelper/        the privileged helper
│   ├── ReqlyMacKit/        Swift package of the Mac-only modules, laid out like core/
│   ├── Config/             .xcconfig files for signing and bundle identifiers
│   └── distribution/       the Homebrew cask
├── windows/                Reqly for Windows, in Phase 2
├── ios/                    the companion app for iPhone and iPad, in Phase 3
├── android/                the companion app for Android, in Phase 4
├── design/                 logo and design guidelines
├── website/                reqly.net: the home page, the docs and the privacy page
├── tools/                  acknowledgements.py, which collects the open-source licenses,
│                           and licenses/, texts the package checkouts lack
├── ARCHITECTURE.md
└── ROADMAP.md
```

- The Xcode project uses folders that stay in sync with the file system, so adding a file doesn't change the project file.
- Signing settings and bundle identifiers live in `.xcconfig` files. Contributors put their own team in an untracked `mac/Config/Local.xcconfig`.

## Testing

- **ReqlyKit** uses Swift Testing.
- **ProxyEngine:**
  - Its handlers are tested with SwiftNIO's `EmbeddedChannel`.
  - End-to-end tests start local HTTP/1.1 and HTTP/2 servers, send requests through the engine with `URLSession`, and check what was recorded. That includes decrypted HTTPS, using a test certificate authority.
- **TrafficStore** is tested with generated sessions of 100,000 requests. This doubles as the speed check.
- **The app:**
  - Feature models are tested with fake services.
  - A few UI tests cover starting and stopping capture, and the certificate setup.
- **CI** on GitHub Actions builds the app, runs the tests and checks formatting with `swift format`. A second job builds and tests the core on Linux, to catch Apple-only code and what behaves differently there. A version tag starts the release workflow, which builds, signs and notarizes Reqly, and drafts a GitHub release.

## Devices

**Phones and tablets on the Wi-Fi.** The engine listens on 127.0.0.1, which only the Mac can reach, until you turn on Allow Devices on This Network. Then it listens on every network the Mac is on.
- The listener moves without dropping the Mac's own connections. Turning devices off again closes theirs.
- A connection from the network waits, with nothing read from it, until it's allowed. A device you turn away leaves no trace in the traffic.
- Reqly asks once for each device, in a sheet, and the Dock shows how many are waiting. A device is told apart by its hardware address, from the Mac's ARP table, so it's still known when its IP address changes. It falls back to the IP address when that's all there is.
- The devices you let in, and the names you give devices, are saved in `~/Library/Application Support/Reqly/Devices.json`. The ones you turn away are asked about again the next time Reqly opens.
- A request for Reqly's own address gets its setup page instead of being forwarded, whether the device opens the address directly or already uses Reqly as its proxy. The page offers the root certificate in DER, which iOS and Android both install, and the steps for each. It's Reqly's own, so it isn't recorded, and it never repeats what the Host header said.
- The Devices window shows the Mac's address with a QR code for the setup page, and the proxy settings to enter.

**Simulators** use the Mac's network settings, so their traffic arrives from the Mac itself while Reqly sets the Mac's proxy.
- SourceResolver labels it with the simulator. An app's path names its simulator's UDID. A simulator's own programs, such as its networking daemon, run under the simulator's `launchd_sim`, whose arguments do. macOS doesn't let other processes read a process's environment, so that's no way to tell.
- Install Certificate runs `simctl keychain add-root-cert` with Xcode's Developer folder, found through Launch Services, since `xcode-select` may point at the Command Line Tools, which have no simulators.

**Android emulators** reach the Mac at 10.0.2.2.
- Use Reqly runs `adb shell settings put global http_proxy 10.0.2.2:<port>`. Copy Certificate pushes the certificate to the emulator's Downloads and opens its security settings, where you install it.
- Their traffic arrives from the Mac, from the emulator's `qemu-system` process. SourceResolver labels it with the virtual device named in that process's `-avd` argument, and credits it to no app, since the app runs inside the emulator.
- What they send over Wi-Fi, the network Android uses first, arrives from `netsimd` instead. The first emulator starts it, and the others share it, so its arguments name no virtual device. SourceResolver labels its traffic with the virtual device of the emulators running, while there's just one, and as "Android Emulator" while there are several, or none. It looks again for each connection, since emulators come and go while `netsimd` runs.

**Apps on phones and emulators.** Reqly can't see which app on a phone, or inside an emulator, opened a connection. For the requests it can read, plain HTTP and the hosts you decrypt, the User-Agent names the app: Apple's networking sends the app's name first, as in `Weather/1 CFNetwork/1498.700.2 Darwin/23.6.0`, and browsers send their own form. Web views and networking libraries, such as okhttp, name no app.
- An encrypted tunnel names nothing: an iPhone's `CONNECT` carries only Host, Proxy-Connection and Connection. Its app stays unknown, and the tunnel shows under its device alone.
- A phone app's icon is the one of the Mac's own copy of the same app, found by bundle ID or by name, such as Safari, Mail or Weather. Otherwise it's a plain icon. Icons are never looked up online, since captured traffic stays on the Mac.

**In the traffic,** every exchange records its device, if it has one, in a device table of its own (storage migration "v6: devices"). The filters, the request list and the detail pane show it. Once a device has sent traffic, the sidebar lists This Mac and each device, each with its apps under it, then the hosts of its traffic from no app Reqly could name, such as a phone's encrypted connections. Each device folds away, and the sidebar's sections close; Reqly remembers which sections are open. Renaming a device renames it in the traffic already saved too.

## Connections

Reqly's own connections to servers can go through another proxy, start from a reverse proxy, and present a client certificate. All three apply to the requests apps send, the ones Reqly sends itself, and encrypted tunnels where it makes sense. `ServerDialer` opens every connection to a server, so they all go the same way.

- **Upstream proxy,** for networks that reach the internet only through one: an HTTP proxy, with an optional user name and password (Basic).
  - HTTPS, requests that switch protocols such as WebSocket, and encrypted tunnels go through a tunnel the proxy opens with `CONNECT`. `UpstreamTunnelHandler` asks for it before anything else goes on the connection. Then TLS, and the HTTP/2 or HTTP/1.1 Reqly speaks with the server, run inside it.
  - Plain HTTP requests go to the proxy with their whole URL, as proxies take them.
  - This Mac is always reached directly. So are the hosts on a bypass list, and, if you choose, local network addresses such as 192.168.1.20 and `.local` names.
  - When the proxy answers 407, or doesn't answer, the exchange fails with what the proxy said, such as that it asks for a user name and password.
  - Changing the proxy closes the encrypted tunnels that now go another way, so apps reconnect. Connections to servers are reused only while the proxy and the client certificates stay the same.
- **Reverse proxies** are local ports, such as `localhost:8080`, that send every request they get to one server, for apps that can't use a proxy.
  - They listen while Reqly captures, on 127.0.0.1 and ::1 only, so the firewall never asks about them.
  - The server gets its own name in the Host header, and redirects to it point back at the reverse proxy, unless you turn that off.
  - The rules act on these requests too, matched by the server's host. SourceResolver finds the app by the port it connected to, as for the proxy port.
- **Client certificates** are read from a `.p12` or `.pfx` file, unlocked with its password, or from PEM files with the certificate and its key. NIOSSL reads both.
  - Reqly keeps the certificate chain and the private key in the Keychain, and never the file's password.
  - A connection to a host the certificate is for presents it when the server asks for one, and the exchange names it only then. The TLS layer says that a server asked, but not on which connection, so each connection holds a TLS setup of its own until it closes; the free ones are used again.
  - When a server asks for a certificate and Reqly has none, or turns the one it got down, the TLS alert says so, and the exchange fails with that.

## Scripts

A script is a rule whose action is JavaScript: `onRequest(request)` runs before a matching request goes to the server, and `onResponse(response, request)` before its response goes back to the app. What a function changes goes on, and `onRequest` can return `respond(status, body, headers)` to answer the request itself.

- **The engine** is QuickJS-ng, compiled into Reqly from its amalgamation, in the CQuickJS target. Its standard library isn't built, so scripts can't reach files, processes or the network.
- **Each run** gets a fresh context, with 1 second, 128 MB of memory and 1 MB of stack. An interrupt handler stops a script at its time limit. Runs happen on four worker threads of their own, with 8 MB stacks, so QuickJS's stack check always fires before the thread's stack runs out. A run goes to the least busy worker, so a script that runs long holds up as few others as can be.
- **What a script gets.** A small prelude, in JavaScript, gives it `Headers` as the Fetch API has it, `console`, `respond` and `shared`. A message reaches the script as JSON: its method and URL, or its status, its headers in order, and its body as text, with `json` parsed when the body is JSON. A body that isn't text, or is over 8 MB, is `null` and goes on unchanged. What comes back is JSON too, so Swift and the script never share objects.
- `async` functions work: their promise runs to the end, since a script has nothing to wait for.
- `shared` is kept as JSON for each script, between its runs, while Reqly runs.
- **What's recorded.** Each run adds a line to the exchange's rules, such as "Changed 1 header." or "Failed: TypeError: …, on line 3.", and what it printed with `console.log` shows in the Overview. A script that fails, or takes too long, leaves the message as it was.
- **The editor** colors JavaScript as you type, checks it as you go by compiling it without running it, starts from examples, and tries the script on a request captured earlier, without sending anything.

## Protobuf and gRPC

BodyKit reads protobuf's wire format itself, so Reqly needs no code generated from your `.proto` files.

- **Without a schema,** each field shows by its number, with a value guessed from its bytes:
  - Length-delimited bytes are text when they read as text, a nested message when they parse as one, and bytes otherwise. Bytes that could be either are text, unless they start the way a message whose first field is number 1 does.
  - Four and eight bytes are a float or a double when they read as an everyday one, and an integer otherwise.
  - Messages nested deeper than 48 levels show as bytes, so a hostile body can't exhaust the stack.
- **`.proto` files** are read by a parser of Reqly's own, for proto2, proto3 and editions: messages, enums, maps, groups, oneofs, extensions and services. Options are skipped.
  - Google's well-known types, such as `Timestamp`, are built in. A timestamp shows as its date, and an `Any` is unpacked when the schema has its type.
  - Type names are looked up the way protoc does, from the innermost scope out. A folder you add brings every file in it, so the types that files import are found too.
  - What Reqly can't use, such as a type no file defines, is listed in Settings, with its file and line. Those fields show by number.
- **Which type a body holds:** the one you chose for bodies like it, then the one a gRPC method takes or returns, from the request's path and the services in your files, then the one the `Content-Type` names. Otherwise it's read without a schema.
- **gRPC framing:** each message has a five-byte prefix that says whether it's compressed and how long it is. Compressed messages are unpacked with the call's `grpc-encoding`. gRPC-Web, its base64 text form and Connect's streams are read too; gRPC-Web ends a response with the call's status, in a part of its own.
- **Status:** a call can fail while its HTTP status is 200, so the list colors it by its `grpc-status` instead, and the detail pane names it.
- The body viewer shows protobuf as text format, the way `protoc --decode` prints it, and as a tree. The tree viewer is the same one JSON uses, through a small `ValueOutline` protocol.

## How the rest of Phase 1 fits

- **Edit, resend and compose:** the engine sends the request straight to the server, with timing like an app's, and it's recorded like any other, credited to Reqly. The rules act on it too. This works whether or not Reqly is capturing.
  - Reqly sets Host and Content-Length from the URL and the body, and leaves out headers meant for a proxy.
  - A server that stops answering for a minute ends the exchange.
- **Session files and HAR import** build on TrafficStore.

## Other platforms

The Windows app in Phase 2 shares the core, and the phone companion apps in Phases 3 and 4 send their traffic to the desktop apps. The core is ready for that:

- The core modules don't import Apple-only frameworks such as Security or ServiceManagement. Platform code lives in its own modules, which `Package.swift` lists only on the Mac. Brotli is the exception, behind `#if canImport(Compression)`.
- CI builds and tests the core on Linux for every change. It's the cheapest way to catch Apple-only code slipping in.
- Session files are SQLite databases that hold everything, bodies included, in one file, so the Windows app can open them as they are.
