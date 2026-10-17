# CZlibBundled

[zlib](https://zlib.net), for gzip and deflate on Windows, which has no zlib to build against. The Mac and Linux use their own zlib through `CZlib`. Its license is in `LICENSE`.

- Version: 1.3.2, from `zlib-1.3.2.tar.gz` in the [v1.3.2 release](https://github.com/madler/zlib/releases/tag/v1.3.2).
- SHA-256 of the archive: `bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16`, as zlib.net lists it.
- The files are the archive's, unchanged: the library's C files and headers, with `zlib.h` and `zconf.h` in `include/`. The `gz*.c` files, zlib's own file reading and writing, are left out: Reqly only unpacks and packs bodies in memory.

To update, replace the files with a newer release's and change the version above.
