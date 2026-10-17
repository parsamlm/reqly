# BoringSSL's assembly for Windows

BoringSSL's fast code for x86-64 PCs, for the TLS that Reqly decrypts HTTPS with on Windows. NIOSSL brings BoringSSL with its assembly for Linux and the Mac. BoringSSL writes its x86-64 assembly for Windows for NASM, which SwiftPM can't run, so without these files BoringSSL is built on Windows in plain C: AES-GCM runs about 30 times slower, and ChaCha20-Poly1305 about 5 times.

- These are BoringSSL's x86-64 Windows files from `gen/bcm` and `gen/crypto`, unchanged, at the revision NIOSSL bundles (its `Sources/CNIOBoringSSL/hash.txt`), which `REVISION` names. They come from [github.com/google/boringssl](https://github.com/google/boringssl), Google's mirror of boringssl.googlesource.com.
- `windows/scripts/build-boringssl-asm.ps1` assembles them with NASM into `CNIOBoringSSLAsm.lib`, with the prefix NIOSSL gives BoringSSL's symbols, from the package's own `boringssl_prefix_symbols_nasm.inc`. The NIOSSL that Reqly builds with on Windows links the library on x86-64, and builds BoringSSL with its assembly there.
- `LICENSE` is BoringSSL's, at that revision.

When NIOSSL moves to a newer BoringSSL, download the same files at the new revision and change `REVISION`. The build script stops while the two differ, since the assembly has to match BoringSSL's C code.
