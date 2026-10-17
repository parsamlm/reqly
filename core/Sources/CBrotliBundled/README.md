# CBrotliBundled

[Brotli](https://github.com/google/brotli)'s decoder, for Brotli-compressed bodies on Windows and Linux, which have no Brotli decoder to build against. The Mac uses Apple's Compression framework instead. Its license is in `LICENSE`.

- Version: 1.2.0, from the source archive of the [v1.2.0 release](https://github.com/google/brotli/releases/tag/v1.2.0).
- SHA-256 of the archive: `816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec`.
- The files are the archive's, unchanged, each matching its blob in the release's git tree: `c/common` and `c/dec` as `common/` and `dec/`, and the decoder's headers from `c/include/brotli` in `include/brotli/`. The encoder is left out: Reqly only unpacks bodies.
- `include/module.modulemap` is Reqly's own: it makes `decode.h` the module's interface.

To update, replace the files with a newer release's and change the version above.
