// Your user's proxy settings for the local network, through WinINet, which Swift's WinSDK module
// leaves out. WinINet's own header can't be built into a module, so it stays in CWinINet.c, and
// this header uses plain C types only. The functions exist on Windows only.

#ifndef CWININET_H
#define CWININET_H

#include <stdint.h>
#include <wchar.h>

/// Reads the settings: WinINet's PROXY_TYPE_ flags, then the proxy server, the addresses to
/// bypass and the setup script, each NULL when empty. Free the text with wininet_free.
/// Returns 0, or the Windows error code.
int32_t wininet_read_proxy(uint32_t *flags, wchar_t **server, wchar_t **bypass, wchar_t **setup_script);

/// Changes the settings, and tells running apps. NULL text clears that setting. Returns 0, or the
/// Windows error code.
int32_t wininet_write_proxy(
    uint32_t flags, const wchar_t *server, const wchar_t *bypass, const wchar_t *setup_script);

/// Frees text that wininet_read_proxy returned.
void wininet_free(wchar_t *text);

#endif
