# Reqly roadmap

Reqly comes in five phases, one platform at a time. Each phase ships when it's ready.

| Phase | Platform | Status |
|---|---|---|
| [1](#phase-1--reqly-for-mac) | Mac | Done |
| [2](#phase-2--reqly-for-windows) | Windows | In progress |
| [3](#phase-3--reqly-for-linux) | Linux | Planned |
| [4](#phase-4--reqly-for-iphone-and-ipad) | iPhone and iPad | Planned |
| [5](#phase-5--reqly-for-android) | Android | Planned |

## Phase 1 — Reqly for Mac

A native app for macOS 26 and later, with what people expect from a traffic inspector. Phase 1 ends with Reqly 1.0.

- [x] Capture your Mac apps' traffic with one switch. Reqly sets the Mac's proxy and always puts it back, even if it quits unexpectedly.
- [x] HTTPS decryption for the hosts you choose, over HTTP/1.1 and HTTP/2.
- [x] A live request list that shows which app sent each request, with filters, search, pins and comments.
- [x] Details for every request: headers, cookies, bodies, timing, and the raw request and response.
- [x] Edit and resend requests, or write new ones.
- [x] Save sessions, open and export HAR files, and copy requests as cURL.
- [x] Breakpoints, Map Local, Map Remote, rewrites, blocking and a slow network.
- [x] Phones and tablets on the same Wi-Fi, iOS Simulators and Android emulators.
- [x] WebSocket, gRPC and Protobuf.
- [x] Upstream proxies, reverse proxies and client certificates.
- [x] Scripts in JavaScript.
- [x] A welcome guide, a menu-bar item, and support for dark mode, the keyboard and VoiceOver.
- [x] Signed releases, automatic updates and a Homebrew cask.

## Phase 2 — Reqly for Windows

Everything from Phase 1 on Windows 11, built on the same core. A session saved on one opens on the other.

- [x] Capture Windows apps' traffic, with HTTPS decryption.
- [x] The request list, details, search and filters.
- [x] Sending and saving, rules and scripts, devices, protocols and connections.
- [x] An icon in the notification area, and automatic updates.
- [ ] A signed installer and winget.

## Phase 3 — Reqly for Linux

Everything from Phase 1 on Debian, Ubuntu and the systems based on them, such as Linux Mint, built on the same core. A session saved on a Mac or a Windows PC opens on Linux, and the other way around.

- [ ] Capture Linux apps' traffic on GNOME and KDE with one switch. Reqly sets your desktop's proxy and always puts it back.
- [ ] HTTPS decryption, set up for your browsers and command-line tools, and removable at any time.
- [ ] A terminal set up for Reqly, so curl, git and other tools are captured too.
- [ ] The request list, details, search and filters.
- [ ] Sending and saving, rules and scripts, devices, protocols and connections.
- [ ] An icon in the notification area, on desktops that show one.
- [ ] A `.deb` package and an apt repository, which keep Reqly up to date.

## Phase 4 — Reqly for iPhone and iPad

A companion app that connects an iPhone or iPad to Reqly on a Mac or Windows PC in a few taps. The desktop app shows the traffic.

- [ ] Pairing by scanning a QR code.
- [ ] A local VPN that sends the device's traffic to Reqly, so apps that ignore proxy settings are captured too.
- [ ] Certificate setup, step by step.
- [ ] Start and stop from the app or from Control Center.
- [ ] On the App Store.

## Phase 5 — Reqly for Android

The same companion app for Android phones and tablets.

- [ ] Pairing by scanning a QR code.
- [ ] A local VPN, with no root needed.
- [ ] Certificate setup, step by step.
- [ ] Which app made each connection, with its name and icon.
- [ ] A Quick Settings tile, and Google Play.
