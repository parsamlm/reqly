#include "CWinINet.h"

#if defined(_WIN32)
#include <windows.h>
#include <wininet.h>

int32_t wininet_read_proxy(uint32_t *flags, wchar_t **server, wchar_t **bypass, wchar_t **setup_script) {
    INTERNET_PER_CONN_OPTIONW options[4];
    ZeroMemory(options, sizeof(options));
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
    INTERNET_PER_CONN_OPTION_LISTW list;
    ZeroMemory(&list, sizeof(list));
    list.dwSize = sizeof(list);
    list.dwOptionCount = 4;
    list.pOptions = options;
    DWORD size = sizeof(list);
    // NULL as the connection means the local network's settings.
    if (!InternetQueryOptionW(NULL, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size)) {
        return (int32_t)GetLastError();
    }
    *flags = options[0].Value.dwValue;
    *server = options[1].Value.pszValue;
    *bypass = options[2].Value.pszValue;
    *setup_script = options[3].Value.pszValue;
    return 0;
}

int32_t wininet_write_proxy(
    uint32_t flags, const wchar_t *server, const wchar_t *bypass, const wchar_t *setup_script) {
    INTERNET_PER_CONN_OPTIONW options[4];
    ZeroMemory(options, sizeof(options));
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    options[0].Value.dwValue = flags;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[1].Value.pszValue = (LPWSTR)server;
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    options[2].Value.pszValue = (LPWSTR)bypass;
    options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
    options[3].Value.pszValue = (LPWSTR)setup_script;
    INTERNET_PER_CONN_OPTION_LISTW list;
    ZeroMemory(&list, sizeof(list));
    list.dwSize = sizeof(list);
    list.dwOptionCount = 4;
    list.pOptions = options;
    if (!InternetSetOptionW(NULL, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list))) {
        return (int32_t)GetLastError();
    }
    // Running apps hear that the settings changed, and read them again.
    InternetSetOptionW(NULL, INTERNET_OPTION_SETTINGS_CHANGED, NULL, 0);
    InternetSetOptionW(NULL, INTERNET_OPTION_REFRESH, NULL, 0);
    return 0;
}

void wininet_free(wchar_t *text) {
    if (text != NULL) {
        GlobalFree(text);
    }
}
#endif
