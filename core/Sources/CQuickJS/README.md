# CQuickJS

[QuickJS-ng](https://github.com/quickjs-ng/quickjs), the JavaScript engine Reqly's scripts run in, built from its amalgamation. Its license is in `LICENSE`.

- Version: 0.17.0, from `quickjs-amalgam.zip` in the [v0.17.0 release](https://github.com/quickjs-ng/quickjs/releases/tag/v0.17.0).
- SHA-256 of the zip: `a0955463c74809173a253ff87365095e6972e8b171cfb6aa8a1e781adf35cfeb`.
- `quickjs-amalgam.c` and `include/quickjs.h` are the zip's files, unchanged. The zip's `quickjs-libc.h` is left out: Reqly doesn't build QuickJS's standard library (`QJS_BUILD_LIBC`), so scripts can't reach files, processes or the network.
- `reqly_quickjs.c` and `include/reqly_quickjs.h` are Reqly's own: they run one script in a fresh context, with time, memory and stack limits.

To update, replace the two files with a newer release's and change the version above.
