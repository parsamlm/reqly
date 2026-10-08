# Reqly roadmap

Reqly comes in four phases, one platform at a time. Each phase ships when it's ready.

| Phase | Platform | Status |
|---|---|---|
| [1](#phase-1--reqly-for-mac) | Mac | In progress |
| [2](#phase-2--reqly-for-windows) | Windows | Planned |
| [3](#phase-3--reqly-for-iphone-and-ipad) | iPhone and iPad | Planned |
| [4](#phase-4--reqly-for-android) | Android | Planned |

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
- [ ] Signed releases, automatic updates and a Homebrew cask.

## Phase 2 — Reqly for Windows

Everything from Phase 1 on Windows 11, built on the same core. A session saved on one opens on the other.

- [ ] Capture Windows apps' traffic, with HTTPS decryption.
- [ ] The request list, details, search and filters.
- [ ] Sending and saving, rules and scripts, devices, protocols and connections.
- [ ] An icon in the notification area, a signed installer, winget and automatic updates.

## Phase 3 — Reqly for iPhone and iPad

A companion app that connects an iPhone or iPad to Reqly on a Mac or Windows PC in a few taps. The desktop app shows the traffic.

- [ ] Pairing by scanning a QR code.
- [ ] A local VPN that sends the device's traffic to Reqly, so apps that ignore proxy settings are captured too.
- [ ] Certificate setup, step by step.
- [ ] Start and stop from the app or from Control Center.
- [ ] On the App Store.

## Phase 4 — Reqly for Android

The same companion app for Android phones and tablets.

- [ ] Pairing by scanning a QR code.
- [ ] A local VPN, with no root needed.
- [ ] Certificate setup, step by step.
- [ ] Which app made each connection, with its name and icon.
- [ ] A Quick Settings tile, and Google Play.
