# Reqly for Linux

[Phase 3](../ROADMAP.md#phase-3--reqly-for-linux) of the roadmap: everything from the Mac app on Debian, Ubuntu and the systems based on them, sharing the Swift core with the Mac and Windows apps. Its code goes in this folder.

The app will run the core in its own process as `libReqlyCore.so`, built from [windows/ReqlyCore](../windows/ReqlyCore), with the same C interface as the Windows app's `ReqlyCore.dll`.

| Folder | What's in it |
|---|---|
| `scripts/` | `core.sh` builds and tests the core, or `libReqlyCore.so`. `stage-core.sh` gathers a release build of `libReqlyCore.so` with the parts of Swift's runtime it needs, and `check-core.sh` checks that they start on a system without Swift, with `smoke.c`, a small program that loads the library and sends a request through it. |

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
