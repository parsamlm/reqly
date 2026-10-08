# ReqlyKit

The core of Reqly: the engine, certificates, rules, scripts, storage and file formats. It's a Swift package with no UI code. The Mac app uses it now, and the Windows app will share it.

The modules that reach the Mac's own services, such as the helper's and the Keychain's, are in [ReqlyMacKit](../mac/ReqlyMacKit), next to the Mac app. [ARCHITECTURE.md](../ARCHITECTURE.md) describes each module.

To run its tests:

```bash
swift test --package-path core
```
