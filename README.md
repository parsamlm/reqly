<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/logo/lockup/reqly-lockup-on-dark.svg">
    <img alt="Reqly" src="design/logo/lockup/reqly-lockup-on-light.svg" width="320">
  </picture>
</p>

# Reqly — Native Network Traffic Inspector for Linux & macOS

**Reqly** is a high-performance, open-source network traffic inspector and debugging proxy. It captures, decrypts, inspects, and modifies HTTP and HTTPS traffic in real time with a native GUI and CLI.

This repository contains both the macOS edition and the **complete standalone native Linux distribution (C++20, GTK3, and OpenSSL)** with full system proxy management, dedicated watchdog crash-guards, and bundled `.deb` packaging.

---

## Table of Contents
- [Overview & What Was Done for Linux](#overview--what-was-done-for-linux)
- [Key Features on Linux](#key-features-on-linux)
- [Architecture & Development](#architecture--development)
- [The Watchdog Daemon (`reqly-guard`)](#the-watchdog-daemon-reqly-guard)
- [HTTPS Inspection & Certificate Setup](#https-inspection--certificate-setup)
- [Building & Installing](#building--installing)
- [Usage & Commands](#usage--commands)
- [Repository Layout](#repository-layout)
- [License](#license)

---

## Overview & What Was Done for Linux

Originally designed for macOS (Swift / SwiftUI), a full-fledged **native Linux distribution** was engineered from the ground up to bring 100% feature and architectural parity to Linux environments (Kali Linux, Ubuntu, Debian, GNOME, etc.).

### What Was Engineered:
1. **Native C++20 Core Proxy Engine:**
   - Asynchronous multi-threaded HTTP/HTTPS forward & MITM proxy listening on `127.0.0.1:9090` (configurable).
   - High-throughput socket handling with dynamic TLS handshakes, SNI inspection, and full bidirectional streaming.
2. **OpenSSL Certificate Authority (CA):**
   - In-memory and on-disk dynamic X.509 certificate generation with SAN (Subject Alternative Names) for intercepting encrypted HTTPS traffic.
3. **Linux Kernel Process Origin Resolver:**
   - Real-time socket inode lookup parsing `/proc/net/tcp` and `/proc/net/tcp6`, combined with `/proc/<pid>/cmdline` and `/proc/<pid>/exe`.
   - Identifies the exact application and Process ID (e.g., `firefox`, `chrome`, `curl`, `python3`) initiating each connection.
4. **Native GTK3 Desktop GUI:**
   - Native dark-mode styled GTK3 desktop interface featuring a HeaderBar, live-updating request table, status badges, response/header viewer, and traffic clearing.
5. **Interactive Dual-Mode Launcher:**
   - Interactive prompt when run in a terminal (`[1] Desktop GUI [2] CLI Inspector`), automatic GUI launch when opened from desktop application menus, and explicit flags (`--gui`, `--cli`).
6. **Dedicated Linux Watchdog Daemon (`reqly-guard`):**
   - Linux counterpart to macOS’s `ReqlyHelper` / `ProxyGuard.swift`.
   - Uses an anonymous kernel pipe (`pipe(2)`) to monitor Reqly's PID. If Reqly crashes, receives `kill -9` (`SIGKILL`), or exits unexpectedly, the watchdog immediately restores the system proxy back to `'none'`, ensuring your internet connection is never broken.
7. **Complete Heavyweight Standalone Bundler (`build_reqly_full.sh`):**
   - A single, self-contained shell script that auto-detects prerequisites, installs required build dependencies, generates source code, compiles binaries across all CPU threads, bundles the Swift 6 Linux runtime libraries and assets into `/opt/reqly`, and builds a standalone `reqly_1.0.0_amd64.deb` package.

---

## Key Features on Linux

| Feature | Details |
|---|---|
| **Live Traffic Inspection** | Inspect method, URL, status code, originating process name, PID, timing, request/response headers, and response bodies. |
| **HTTPS Decryption (MITM)** | Dynamic SSL/TLS interception using a custom OpenSSL Root Certificate Authority. |
| **Process Origin Resolver** | Identifies which local process sent the request directly via Linux `/proc` filesystem. |
| **Rules Engine** | Supports request/response rewrites, URL redirection, Map Local, Map Remote, blocking, and latency throttling. |
| **Zero-Crash Proxy Guard** | Dedicated watchdog daemon (`reqly-guard`) guarantees system proxy is restored even on uncatchable `SIGKILL` or power loss. |
| **Dual Interface** | Full GTK3 desktop window or lightweight CLI terminal logger. |
| **Desktop Integration** | GNOME/KDE desktop menu launcher (`reqly.desktop`), application icon integration (`hicolor` scalable SVG and 128x128 PNG), and `/usr/bin/reqly` wrapper. |

---

## Architecture & Development

The Linux distribution is built using **C++20** and native Linux system APIs for maximum speed and zero JVM/Electron overhead:

```
┌─────────────────────────────────────────────────────────────┐
│                       User Interface                        │
│         GTK3 Desktop GUI    │    Interactive CLI Runner     │
└───────────────────────────────┬─────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────┐
│                      Reqly Core Engine                      │
│   ┌───────────────────────┐     ┌───────────────────────┐   │
│   │   ProxyServer (MITM)  │     │   Rules Engine        │   │
│   └───────────┬───────────┘     └───────────────────────┘   │
│               │                                             │
│   ┌───────────▼───────────┐     ┌───────────────────────┐   │
│   │ CertificateAuthority  │     │ TrafficStorage        │   │
│   │    (OpenSSL X509)     │     │   (Thread-Safe Ring)  │   │
│   └───────────────────────┘     └───────────────────────┘   │
│               │                                             │
│   ┌───────────▼───────────┐     ┌───────────────────────┐   │
│   │ Process Resolver      │     │ LinuxSystemProxy      │   │
│   │   (/proc/net/tcp)     │     │   (gsettings / dconf) │   │
│   └───────────────────────┘     └───────────┬───────────┘   │
└─────────────────────────────────────────────┼───────────────┘
                                              │ Kernel Pipe
                                  ┌───────────▼───────────┐
                                  │      reqly-guard      │
                                  │   (Watchdog Daemon)   │
                                  └───────────────────────┘
```

- **`src/core/proxy_server.cpp`**: Multi-threaded TCP socket listener, HTTP parser, and HTTPS CONNECT tunnel handler.
- **`src/core/ca.cpp`**: RSA 2048-bit Certificate Authority generating dynamic host certificates signed by `Reqly CA`.
- **`src/core/process_resolver.cpp`**: Maps client source port to Linux socket inodes, inspecting `/proc/<pid>/fd` to extract process name and executable path.
- **`src/core/proxy_guard.cpp` & `src/guard/guard_main.cpp`**: Kernel-pipe watchdog daemon and launch recovery manager.
- **`src/gui/gui_runner.cpp`**: GTK3 interface using Paned layout, ListStore, and TreeView.
- **`src/cli/cli_runner.cpp`**: ANSI terminal output with color-coded traffic logging.

---

## The Watchdog Daemon (`reqly-guard`)

### Why It Is Needed
When Reqly begins capturing, it configures your desktop environment (GNOME / dconf) to direct traffic through `127.0.0.1:9090`. If Reqly terminates unexpectedly without turning this setting off, browsers will report *"Connection Refused"*.

On macOS, Reqly solved this with `ReqlyHelper` and `ProxyGuard.swift`. On Linux, we achieved parity using **`reqly-guard`**:

1. **Anonymous Kernel Pipe:** When Reqly starts capturing, it opens a kernel pipe (`pipe(2)`) and spawns `reqly-guard` in the background with the read end of the pipe.
2. **Instant Exit Detection:** `reqly-guard` blocks on `read()`. If Reqly exits normally, crashes with a segmentation fault, or is killed via `kill -9` (`SIGKILL`), the Linux kernel automatically closes all open file descriptors for the dead process.
3. **Immediate Cleanup:** The moment the pipe closes (EOF), `reqly-guard` immediately runs `gsettings set org.gnome.system.proxy mode 'none'`, resets proxy settings across all active `/run/user/<UID>/bus` desktop sessions, and cleans up state files.
4. **Boot / Launch Recovery:** If the computer loses power or reboots while proxy mode was active, `ProxyGuard::recoverAtLaunch()` inspects `/tmp/reqly-proxy-state.json` on the next launch and cleans up stale settings automatically.

---

## HTTPS Inspection & Certificate Setup

Because HTTPS connections are encrypted, web browsers protect users by rejecting any unknown Certificate Authority.

> **Important Note:**  
> On Linux, web browsers (especially Firefox, which maintains its own private certificate database) need to be told to trust Reqly CA.

When visiting an HTTPS site while capturing, Firefox may display:
> *"Software is Preventing Firefox From Safely Connecting to This Site... This issue is caused by Reqly CA"*

This is completely normal and confirms that Reqly is actively intercepting and decrypting traffic.

### Configuring Firefox (One-Time Setup)

#### Option A: Trust System Certificates in Firefox (Recommended)
1. Open Firefox and type `about:config` into the address bar.
2. Click **"Accept the Risk and Continue"**.
3. Search for:
   ```text
   security.enterprise_roots.enabled
   ```
4. Double-click it to set its value to **`true`**.
5. Restart Firefox. Firefox will now trust local enterprise / proxy root certificates.

#### Option B: Import Reqly CA Certificate into Firefox
1. Locate the exported root certificate generated by Reqly (`reqly-ca.crt` or `~/.config/reqly/reqly-ca.crt`).
2. In Firefox, open **Settings** (`about:preferences#privacy`).
3. Scroll down to **Certificates** and click **View Certificates...**.
4. In the **Authorities** tab, click **Import...**.
5. Select `reqly-ca.crt`.
6. Check **"Trust this CA to identify websites"** and click **OK**.

---

## Building & Installing

The Linux distribution includes a fully self-contained builder script: [`build_reqly_full.sh`](build_reqly_full.sh).

### 1. Build the Heavyweight Bundled Package
Run the builder with `sudo` (required to verify build packages and build system layout):

```bash
sudo ./build_reqly_full.sh
```

The script will automatically:
- Install all necessary build tools (`cmake`, `ninja-build`, `build-essential`, `pkg-config`, `libgtk-3-dev`, `libssl-dev`, `dpkg-dev`).
- Generate all C++ source files and CMake configurations in `linux-dists/`.
- Compile both `reqly` and `reqly-guard` using all available CPU threads (`ninja -j$(nproc)`).
- Bundle the full runtime, Swift 6 Linux shared libraries, icons, and desktop entries into `/opt/reqly`.
- Generate a standalone Debian package: **`reqly_1.0.0_amd64.deb`**.

### 2. Install the `.deb` Package

```bash
sudo dpkg -i reqly_1.0.0_amd64.deb
```

---

## Usage & Commands

### Launching the Application
- **From Application Menu:** Search for **Reqly** in your application launcher (GNOME, Kali, MATE, KDE) and click to open the GUI.
- **From Terminal (Interactive Menu):**
  ```bash
  reqly
  ```
  Presents a selection prompt:
  ```text
  Reqly Network Traffic Inspector
  Select interface mode:
    [1] Desktop GUI (Full Application)
    [2] CLI Inspector (Terminal Mode)
  Choice [1/2] (default: 1):
  ```
- **Direct GUI Launch:**
  ```bash
  reqly --gui
  ```
- **Direct Terminal Mode:**
  ```bash
  reqly --cli
  ```
- **Custom Port:**
  ```bash
  reqly --gui --port 8080
  ```

### Manual Proxy Reset / Recovery
If you ever want to forcefully restore system proxy settings to `'none'` without launching the UI:
```bash
reqly --restore-proxy
# or via the watchdog utility:
reqly-guard --restore
```

---

## Repository Layout

| Directory / File | Description |
|---|---|
| [`build_reqly_full.sh`](build_reqly_full.sh) | Self-contained, multi-threaded builder and packager for the complete Linux `.deb` distribution. |
| [`linux-dists/`](linux-dists/) | Generated Linux workspace containing C++ source files, CMake config, and build artifacts. |
| [`mac/`](mac/) | Reqly for macOS: Xcode project, SwiftUI interface, and `ReqlyHelper` daemon. |
| [`core/`](core/) | Shared Swift `ReqlyKit` package (engine, certificates, rules, storage). |
| [`design/`](design/) | Official SVG and PNG logos, lockups, icons, and visual guidelines. |
| [`ROADMAP.md`](ROADMAP.md) | Multi-phase development roadmap (macOS, Linux, Windows, Mobile companion apps). |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Architectural documentation of Reqly's core systems. |

---

## License

Reqly is released under the [MIT License](LICENSE). The Reqly name and logo are protected trademarks; see [TRADEMARKS.md](TRADEMARKS.md).
