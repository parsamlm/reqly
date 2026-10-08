<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/logo/lockup/reqly-lockup-on-dark.svg">
    <img alt="Reqly" src="design/logo/lockup/reqly-lockup-on-light.svg" width="320">
  </picture>
</p>

Reqly is an open-source network traffic inspector. It shows what your apps send and receive, clearly laid out, in a native app. It starts on the Mac and then comes to Windows. Companion apps for iPhone, iPad and Android will send a phone's traffic to it.

> [!NOTE]
> Reqly is in early development. Phase 1 is under way; see the [roadmap](ROADMAP.md).

## Features

Everything here works today in Reqly for Mac. What comes next is in the [roadmap](ROADMAP.md).

| Feature | What it does |
|---|---|
| **Capture** | Captures your Mac apps' traffic with one switch, in the window or the menu bar. A small helper sets the Mac's proxy and always puts it back, even if Reqly quits unexpectedly. macOS asks you to allow it once. |
| **HTTPS** | Decrypts only the hosts you choose, with wildcards such as `*.example.com`, over HTTP/1.1 and HTTP/2. Reqly creates its own certificate on your Mac. Every other host passes through untouched. |
| **Setup** | A welcome window walks you through installing the certificate and choosing the hosts to decrypt. |
| **Request list** | Shows traffic live, with the app or tool that sent each request and its icon. Filter by status, app, device, host, method and content type. |
| **Details** | Headers, cookies, bodies, and the raw request and response. Bodies show as formatted JSON or a tree, colored XML and HTML, images, forms and hex. |
| **Timing** | Each step of a request: the DNS lookup, connecting, the TLS handshake, sending, waiting and downloading, plus the server's address and whether the connection was reused. |
| **Search** | Searches URLs, headers, bodies and your comments, including compressed bodies. |
| **Pins** | Pin requests, mark them with a color and add comments. Pinned requests stay when you clear the list. |
| **Resend** | Resend a request, edit it first, or write a new one. Reqly records it like any other. |
| **Rules** | Change traffic as it passes: breakpoints that pause a request or response for editing, Map Local, Map Remote, rewrites, blocking, and a slow network such as 3G. |
| **Scripts** | JavaScript that changes requests and responses as they pass, or answers requests itself. Start from an example and try it on a captured request. Scripts can't reach your files or the network. |
| **Devices** | Phones and tablets on the same Wi-Fi join with a QR code and a certificate page, and Reqly asks before letting each one in. iOS Simulators get the certificate in one click, and Android emulators are set up through adb. |
| **Protocols** | WebSocket messages in order, in either direction. gRPC and Protobuf decoded into readable fields, with names and types once you add the `.proto` files. |
| **Connections** | An upstream proxy, reverse proxies for apps that can't use a proxy, and client certificates for servers that ask for one. |
| **Sessions** | Save a session and open it later, open and export HAR files, and copy requests as cURL. Authorization headers and cookies can be hidden when you share. |
| **Storage** | Traffic is kept on disk while Reqly runs, so long sessions don't fill the memory. Quitting deletes it. |
| **Privacy** | Your traffic stays on your Mac, and Reqly has no analytics. It only checks GitHub once a day for a newer version, which you can turn off. After a crash, it offers a GitHub issue for you to read and submit. |

## Building

You need macOS 26 or later and Xcode 27.

1. Open `mac/Reqly.xcodeproj`.
2. Choose the Reqly scheme and press ⌘R.

Builds are signed to run on your own Mac. To sign with your Apple developer team, which the helper needs, copy `mac/Config/Local.example.xcconfig` to `mac/Config/Local.xcconfig` and fill in your team. A free Apple ID team works for local builds.

Builds that aren't signed by a team can't use the helper. They capture only apps you point at Reqly yourself, for example:

```bash
curl -x 127.0.0.1:9090 http://example.com
```

Debug builds are `net.reqly.Reqly.debug`, so they have their own helper and settings, apart from a released Reqly's. macOS asks you to allow each helper once.

Everything that isn't UI lives in two packages, with their tests: ReqlyKit, in `core`, and the Mac-only modules' ReqlyMacKit, in `mac/ReqlyMacKit`:

```bash
swift test --package-path core
swift test --package-path mac/ReqlyMacKit
```

## Repository layout

Each platform has a folder of its own, and the code they share sits beside them:

| Folder | What's in it |
|---|---|
| [core](core) | ReqlyKit, the Swift package with the engine, certificates, rules, scripts, storage and file formats. The Mac app uses it now, and the Windows app will share it. |
| [mac](mac) | Reqly for Mac: the Xcode project, the app, its helper, ReqlyMacKit with the modules that reach the Mac's own services, and the Homebrew cask. |
| [windows](windows) | Reqly for Windows, which comes in Phase 2. |
| [ios](ios) | The companion app for iPhone and iPad, which comes in Phase 3. |
| [android](android) | The companion app for Android, which comes in Phase 4. |
| [design](design) | The logo and the design guidelines, for every platform. |
| [website](website) | reqly.net: the home page, the docs and the privacy page. |
| [tools](tools) | Scripts for maintaining the project, such as collecting the open-source licenses. |

## Learn more

- [Roadmap](ROADMAP.md): what Reqly does, phase by phase.
- [Architecture](ARCHITECTURE.md): how it's built.
- [Design guidelines](design/GUIDELINES.md): its logo, colors, type and icons.

## License

Reqly is released under the [MIT License](LICENSE). The Reqly name and logo aren't covered by it; see [TRADEMARKS.md](TRADEMARKS.md).
