# Reqly for Mac

The Mac app, [Phase 1](../ROADMAP.md#phase-1--reqly-for-mac) of the roadmap.

| Folder | What's in it |
|---|---|
| `Reqly.xcodeproj` | The Xcode project. Open it, choose the Reqly scheme, and press ⌘R. |
| `Reqly/` | The app: its scenes, features, AppKit views and resources. |
| `ReqlyHelper/` | The privileged helper that sets the Mac's proxy and always puts it back. |
| `ReqlyMacKit/` | A Swift package with the modules that reach the Mac's own services: the helper's, the Keychain's, the process table, and simulators and emulators. Test it with `swift test --package-path mac/ReqlyMacKit`. |
| `Config/` | The `.xcconfig` files. Copy `Local.example.xcconfig` to `Local.xcconfig` to sign with your own team. |
| `distribution/` | The Homebrew cask. |

The rest of what isn't UI is in ReqlyKit, in [core](../core), which the Windows app will share. [ARCHITECTURE.md](../ARCHITECTURE.md) explains how the parts fit together.
