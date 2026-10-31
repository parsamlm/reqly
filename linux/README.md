# Reqly for Linux

[Phase 3](../ROADMAP.md#phase-3--reqly-for-linux) of the roadmap: everything from the Mac app on Debian, Ubuntu and the systems based on them, sharing the Swift core with the Mac and Windows apps. Its code goes in this folder.

The app is Swift, with GTK 4 and libadwaita, and links the core and the [core interface](../core-interface) directly, in one process. `libReqlyCore.so`, built from [windows/ReqlyCore](../windows/ReqlyCore), stays a check that the core interface builds and runs on Linux.

| Folder | What's in it |
|---|---|
| `Package.swift`, `Sources/`, `Tests/` | The `ReqlyLinux` package: the app, the program `reqly` (`ReqlyApp`, with `AppSetup` for its command line, settings and folders), on GTK 4 and libadwaita through `CGtk`, `CGtkShim` and `GtkBinding`; and what only Linux has, which the app hands the core as its `SystemParts`, as `WindowsSystem` does on Windows. `LinuxDesktop` sets your desktop's proxy, `LinuxTrust` keeps and trusts Reqly's certificate, `LinuxApps` finds which app opened a connection, and `LinuxSystem` puts them together. `CGio`, `CSecret` and `CLinux` reach GIO, libsecret and the kernel. |
| `packaging/` | `reqly-trust`, the helper that adds Reqly's root to the computer's list as root, and its polkit action, `net.reqly.trust.policy`; `net.reqly.Reqly.desktop`, the app's desktop file. |
| `docker/` | The image the package is built and tested in, `reqly-linux-dev:noble`: Ubuntu 24.04 with Swift 6.4.1 and the development packages. |
| `scripts/` | `app.sh` builds and tests the package, and runs the app's self-check through `self-check.sh`. `core.sh` builds and tests the core, or `libReqlyCore.so`. `stage-core.sh` gathers a release build of `libReqlyCore.so` with the parts of Swift's runtime it needs, and `check-core.sh` checks that they start on a system without Swift, with `smoke.c`, a small program that loads the library and sends a request through it. |

## Building the package

In `reqly-linux-dev:noble`, so it builds against Ubuntu 24.04's headers, the oldest Reqly supports. Where Docker is, such as on a Mac with Colima, `app.sh` runs the build in the image, with the repository mounted read-only and the build kept in a Docker volume, `reqly-linux-build` unless `--volume` names another. Without Docker, such as in a container of the image, it builds in place.

```bash
docker build -t reqly-linux-dev:noble linux/docker
linux/scripts/app.sh build
linux/scripts/app.sh test
linux/scripts/app.sh build --target LinuxDesktop      # one module and what it uses
linux/scripts/app.sh test --filter LinuxDesktopTests  # one module's tests
```

## The app

`reqly` is Swift calling GTK 4 and libadwaita's C API directly, built against Ubuntu 24.04's headers: GTK 4.14 and libadwaita 1.5. Anything newer is looked up as it runs, after a version check, with `GtkBinding`'s `Newer`, and has a fallback. `CGtkShim` is the little C that Swift can't write: GObject's macros as functions, one marshaller for every signal, and a GLib source that runs Swift's main queue, so the main actor, and the session's events, run inside GTK's main loop.

A real run is the only Reqly: a second launch brings back the first one's window and quits, through GApplication's name on the session bus, `net.reqly.Reqly`. SIGTERM, SIGINT and SIGHUP quit it as the menu does, so capturing stops and your desktop's proxy goes back first. A run given a stand-in, its own settings file, `--app-id` or `--smoke` is a test run: it runs beside the Reqly that's open, and changes your desktop's own proxy only when told to. `reqly --help` lists the options, with the Windows app's names.

| Where | What |
|---|---|
| `~/.config/reqly` | `Settings.json`, `Rules.json`, `Connections.json`, `Protobuf.json` and `Devices.json`, in the same JSON as Windows' |
| `~/.local/state/reqly` | `Sessions`, the live sessions, which only you can open and which go when Reqly quits; `ProxyRestore.json`, your proxy settings while Reqly captures |
| `~/.local/share/reqly` | Reqly's certificate, and its key and the other secrets when there's no keyring |

`Sources/ReqlyApp` keeps each feature in a folder of its own: `Capture`, `HTTPS`, `Terminal` and `Traffic`. Capturing and HTTPS list their parts of the self-check in `SelfCheck/CaptureChecks.swift` and `SelfCheck/HTTPSChecks.swift`. The window, the model, Settings and the menu's actions are shared, in `MainWindow.swift`, `AppModel.swift`, `SettingsDialog.swift` and `App.swift`. `Tests/ReqlyAppTests` tests what the app decides without a window, such as the status line's words, the rows and the icons' rules.

The self-check runs the app headless, under Xvfb on a session bus of its own, with a scratch home, GSettings in memory and stand-ins for your proxy settings, certificate and secrets, and prints a report with PASS or FAIL for each part:

```bash
linux/scripts/app.sh self-check                         # every part
linux/scripts/app.sh self-check --smoke-parts window    # one part
```

Where Docker is, it runs in a container of its own, as an ordinary account, with no network but its own 127.0.0.1. CI runs it after the tests, as the image's ordinary account too, since one part takes a folder's write permission away, which root ignores.

### On a desktop

Until there's a package, a release build with Swift's runtime inside the program runs on a desktop, such as a VM's, with only the system's own libraries, GTK 4, libadwaita and libsecret among them, on Ubuntu 24.04 and 26.04 and Debian 13. Docker builds it for its own architecture, arm64 on a Mac:

```bash
linux/scripts/app.sh build -c release --product reqly --static-swift-stdlib
docker run --rm -v reqly-linux-build:/build:ro reqly-linux-dev:noble cat /build/release/reqly > reqly
```

Then, on the desktop, with the repository's files beside it, install the program, the desktop file and the icon for your account:

```bash
install -D -m 0755 reqly ~/.local/bin/reqly
install -D -m 0644 linux/packaging/net.reqly.Reqly.desktop ~/.local/share/applications/net.reqly.Reqly.desktop
install -D -m 0644 design/logo/exports/reqly-icon.svg ~/.local/share/icons/hicolor/scalable/apps/net.reqly.Reqly.svg
```

A real run points that desktop's proxy setting at Reqly while it captures, and Set Up HTTPS changes its browsers and, with a password, the computer's list. A test run with stand-ins and files of its own, as the self-check's, changes none of it, and runs beside a real one:

```bash
t=/tmp/reqly-test && mkdir -p $t
reqly --settings-file $t/Settings.json --rules-file $t/Rules.json --connections-file $t/Connections.json \
    --protobuf-file $t/Protobuf.json --devices-file $t/Devices.json --sessions-folder $t/Sessions \
    --proxy-settings-stand-in $t/ProxySettings.json --proxy-restore-file $t/ProxyRestore.json \
    --root-stand-in $t/Root.dat --root-file $t/Certificate.dat --secrets-stand-in $t/Secrets.json \
    --allows-network-devices no --checks-for-updates no --has-seen-welcome yes
```

With `--sets-system-proxy no` in place of the proxy's stand-in, it leaves the proxy alone, and captures what you point at 127.0.0.1 on its port, such as a terminal from Open Terminal.

- `reqly --remove-certificate` removes Reqly's certificate for your account, with no window: from the browsers, Firefox and the computer's list, which asks for an administrator's password, in the terminal when there's no password dialog, as over SSH, and its key. It says how each place went, and exits with 0 only once nothing of it is left. With `--root-stand-in`, only the stand-in goes.
- `reqly --restore-proxy <restore file>` is the login entry's run, and `--restore-proxy-after <process> <restore file>` the watcher's, which waits for that Reqly to end. Each puts your proxy settings back from the restore file once Reqly isn't running, while Reqly's are still in place, and does nothing else. Run the first with `~/.local/state/reqly/ProxyRestore.json` to put them back by hand; Reqly also puts them back as it opens.
- Set Up HTTPS adds the certificate to the computer's list through `reqly-trust`, which pkexec runs as root. To check it before there's a package, install it and its polkit action where the package will, so pkexec's dialog says what Reqly is about to do:

  ```bash
  sudo install -D -m 0755 linux/packaging/reqly-trust /usr/libexec/reqly/reqly-trust
  sudo install -D -m 0644 linux/packaging/net.reqly.trust.policy /usr/share/polkit-1/actions/net.reqly.trust.policy
  ```

  Or install a copy elsewhere, where only root can change it, and name it with `--trust-helper`, for which pkexec asks its general question instead:

  ```bash
  sudo install -D -m 0755 linux/packaging/reqly-trust /usr/local/libexec/reqly/reqly-trust
  reqly --trust-helper /usr/local/libexec/reqly/reqly-trust
  ```

  The browsers' certificate databases need `certutil`, from `libnss3-tools`, which Ubuntu and Debian don't install by themselves; the package will depend on it.

## Building the core

On Ubuntu 24.04 with Swift 6.4.1, `libsqlite3-dev` and `zlib1g-dev`, as in the `swift:6.4.1-noble` image (Swift 6.2's optimizer crashes on a release build of `windows/ReqlyCore`). The scripts have been tested on arm64; CI runs them on x64 and arm64.

```bash
linux/scripts/core.sh test                          # the core's tests
linux/scripts/core.sh test --package ReqlyCore      # the C interface's tests
linux/scripts/core.sh build --package ReqlyCore -c release
linux/scripts/stage-core.sh linux/.build/core
```

`linux/.build/core/lib` then holds `libReqlyCore.so`, the parts of Swift's runtime it needs, and `swift-backtrace`, which the runtime starts to write a crash's report. Each looks for libraries only beside itself, so Reqly uses its own copy of the runtime even on a computer with Swift installed, unless `LD_LIBRARY_PATH` names a toolchain's libraries, which the loader looks in first; `stage-core.sh` fails if `libReqlyCore.so` was built to look anywhere else. They keep their function names, for crash reports; the debug information is apart, in `linux/.build/core/debug`, as Windows keeps its PDBs. `stage-core.sh` stages only into a new or empty folder, or over an earlier stage (`lib/`, `debug/` and `test/` and nothing else), and replaces only those three folders.

Built on Ubuntu 24.04, they need glibc 2.38 or newer, and from the system only libc, libm, libgcc_s, libstdc++, SQLite (`libsqlite3-0`) and zlib (`zlib1g`). They don't need libxml2, since BodyKit reads XML with code of its own, on every platform, rather than with Foundation's XML. To check that they start on another system, run this there, with those packages and no Swift:

```bash
linux/scripts/check-core.sh linux/.build/core
```

It fails unless:

- every file in `lib/` finds each library it needs, each library that's in `lib/` loads from there, and nothing loads from a Swift toolchain;
- nothing needs libxml2, which has another name on Ubuntu 26.04 and Debian 14 (`libxml2.so.16`) than on Ubuntu 24.04 and Debian 13 (`libxml2.so.2`), and `lib/` has no `libFoundationXML.so`, Foundation's XML, which needs it;
- `test/smoke`, built from `smoke.c`, loads `libReqlyCore.so` with Swift's runtime from `lib/`, opens a session, sends a request through Reqly to a server of its own on 127.0.0.1, sees it in the session and closes it, all within a minute;
- when the core crashes on purpose, `lib/swift-backtrace` writes a report that names `libReqlyCore.so`.
