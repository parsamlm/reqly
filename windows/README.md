# Reqly for Windows

The Windows app, [Phase 2](../ROADMAP.md#phase-2--reqly-for-windows) of the roadmap: everything from the Mac app, on Windows 11. It's in progress, and not ready to use yet.

Its screens are WinUI 3, in C#. Everything else is the same Swift core as the Mac app's, in [core](../core), which the app runs in its own process as `ReqlyCore.dll`.

| Folder | What's in it |
|---|---|
| `Reqly/` | The app: its windows, in WinUI 3, and the C# side of the core's interface. |
| `ReqlyCore/` | A Swift package that builds `ReqlyCore.dll`: the core, with a small C interface that carries JSON messages (`ReqlyCore.h`), and the pieces that reach Windows' own services: your proxy setting, your certificate store, the connection table, this PC's network addresses and its neighbors' hardware addresses, and the data protection that keeps secrets for your user. Its tests also run on the Mac and Linux, with `swift test --package-path windows/ReqlyCore`. |
| `scripts/` | `app.ps1` builds the app, and `core.ps1` builds and tests the core on Windows, first running `build-sqlite.ps1`, which builds SQLite, `patch-packages.ps1`, which applies `patches/`, and `build-boringssl-asm.ps1`, which assembles BoringSSL's assembly. `package.ps1` makes the installer. |
| `distribution/` | The templates for Reqly's listing in winget, Windows' package manager, which `package.ps1` fills in for each version. |
| `patches/` | Fixes for Windows to SwiftNIO and swift-nio-ssl that their releases don't have yet, which every build applies by itself. |
| `third-party/` | SQLite, which Reqly brings on Windows, since Windows has none to build against, and BoringSSL's assembly for x86-64 Windows, which SwiftPM can't build. |

## Building

On Windows 11 with Swift 6.4, Visual Studio Build Tools 2022 (with the Windows SDK), the .NET 10 SDK and [NASM](https://www.nasm.us) (2.16 or newer, on the PATH, in `NASM`, or in `windows\.build\nasm`):

```powershell
.\windows\scripts\build-sqlite.ps1
.\windows\scripts\app.ps1
```

SwiftNIO and swift-nio-ssl don't work on Windows in their releases yet, so the build downloads the versions Reqly pins and applies Reqly's patches to them, from `patches/`, which says what each one fixes and where it stands upstream. swift-nio-ssl's patches also have it link BoringSSL's assembly, which `core.ps1` assembles with NASM first, since SwiftPM can't (`third-party/boringssl-asm`). Editing those packages makes links in `Packages/`, which Windows allows with Developer Mode on, or as an administrator.

## Packaging

The installer comes from [Velopack](https://velopack.io), whose `vpk` tool is pinned in `.config/dotnet-tools.json`:

```powershell
.\windows\scripts\package.ps1
```

It builds Reqly for release with .NET and the Windows App SDK inside it, and the Swift runtime's DLLs beside it, so a PC needs none of them installed. In `windows\.build\releases` it leaves `Reqly.App-win-Setup.exe`, which installs Reqly for your user alone, without asking for administrator rights; the package and `releases.win.json`, from which installed copies update themselves; and winget's manifests for the version. The version is the `<Version>` in `Reqly/Reqly.csproj`. To package a version again, add `-Replace`.

The script stops if Reqly needs a runtime DLL whose license isn't in the app's list of open-source licenses, or a runtime of a different version than the list has, or a part of the Visual C++ runtime that isn't beside it. Builds aren't signed yet.

[ARCHITECTURE.md](../ARCHITECTURE.md) explains how the parts fit together.
