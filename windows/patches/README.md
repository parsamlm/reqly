# Patches for Windows

Reqly's engine is built on SwiftNIO and swift-nio-ssl, whose releases don't work on Windows yet: SwiftNIO has bugs there, and swift-nio-ssl supports Windows only in an open pull request. Until their releases catch up, Reqly for Windows builds them with the patches in this folder. The Mac app, and the Linux checks, use their releases as they are.

`windows/scripts/core.ps1` takes care of it before every build, through `windows/scripts/patch-packages.ps1`. For each folder here, named after a package, that script downloads the version in the folder's `VERSION` file from the package's own repository, applies the folder's patches in name order, and has SwiftPM build with that copy instead (an edited package, in SwiftPM's words). The copies are in `windows/.build/patched`, and are made again only when the version or a patch changes. Editing a package makes a link to it in `Packages/`, which Windows allows with Developer Mode on, or as an administrator.

`VERSION` must be the version ReqlyKit pins: both that script and `tools/acknowledgements.py` stop if it isn't. SwiftPM leaves edited packages out of `Package.resolved` when it builds, so `core.ps1` puts the file back as it was afterwards, and Git doesn't see it change. A `swift build` run by hand on Windows does change it: don't commit that change.

| Patch | What it does | Upstream |
|---|---|---|
| `swift-nio/0001-data-path-backpressure.patch` | Winsock's "would block" from sends and reads becomes backpressure instead of a fatal error | [apple/swift-nio#3704](https://github.com/apple/swift-nio/pull/3704), unchanged |
| `swift-nio/0002-wsapoll-and-read-fixes.patch` | Reqly's fixes: sockets that are deregistered leave WSAPoll's set at once; `POLLHUP` is the end of input, not a reset; the read in `Windows.swift` handles "would block" too | Related: [apple/swift-nio#3706](https://github.com/apple/swift-nio/pull/3706), [apple/swift-nio#3715](https://github.com/apple/swift-nio/pull/3715) |
| `swift-nio-ssl/0001-windows-support.patch` | Windows support | [apple/swift-nio-ssl#567](https://github.com/apple/swift-nio-ssl/pull/567), unchanged, without its CI files |
| `swift-nio-ssl/0002-fixes.patch` | Reqly's fixes to that support: a duplicate symbol beside swift-crypto's BoringSSL, and a crash unlocking memory | Not sent yet |
| `swift-nio-ssl/0003-boringssl-assembly.patch` | Links BoringSSL's x86-64 assembly, which `windows/scripts/build-boringssl-asm.ps1` assembles with NASM | Reqly's own: it needs a step outside SwiftPM |

Each patch starts with what it does and where it comes from. Reqly's own changes are under the package's license, the Apache License 2.0, and the app's list of open-source licenses says the packages were changed.

## When SwiftNIO or swift-nio-ssl updates

After updating either package in ReqlyKit and `windows/ReqlyCore`, put its new version, revision and repository in `VERSION`, and build on Windows. If a patch no longer applies, `patch-packages.ps1` stops and names it. To update one, check out the new version, apply the patches before it, apply what still fits of that one, fix the rest, and save `git diff` under the same name, keeping its first lines. When a release has a patch's fix, delete the patch; when a package needs none, delete its folder.
