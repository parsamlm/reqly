# Saved sessions

Sessions that other versions of Reqly, and other systems, saved. `SessionCompatibilityTests` opens each one on every system the tests run on, and checks that it reads as `SessionSample` does: every request, body, annotation, rule, script line and WebSocket message.

| File | Saved by |
|---|---|
| `Mac 1.0.reqly` | The core of Reqly for Mac 1.0, from commit `4c047b7`, with `SessionSample.swift` built against it, on macOS 27 with the system's SQLite. |
| `Windows.reqly` | The Windows build of the core, on Windows 11 with the SQLite Reqly bundles there: `REQLY_SAVE_SESSION_SAMPLE=<folder>\Windows.reqly`, then `windows\scripts\core.ps1 test --filter SessionCompatibilityTests/savesTheSample`. |

`Mac 1.0.reqly` stands for the sessions people already have, so it stays as Reqly for Mac 1.0 saved it. `SessionSample` keeps to what that core has. To test something newer, add a sample and a file of its own, rather than changing these.
