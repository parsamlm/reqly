#include "system_proxy.hpp"
#include "proxy_guard.hpp"
#include <cstdio>
#include <array>
#include <unistd.h>

namespace reqly {

LinuxSystemProxy::~LinuxSystemProxy() {
    if (m_enabled) disable();
}

std::string LinuxSystemProxy::runCommand(const std::string& cmd) {
    std::array<char, 128> buf;
    std::string result;
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) return "";
    while (fgets(buf.data(), buf.size(), pipe) != nullptr) result += buf.data();
    pclose(pipe);
    while (!result.empty() && (result.back() == '\n' || result.back() == '\r')) result.pop_back();
    return result;
}

bool LinuxSystemProxy::enable(int port) {
    m_prevMode = runCommand("gsettings get org.gnome.system.proxy mode 2>/dev/null");
    if (m_prevMode.empty()) m_prevMode = "'none'";
    runCommand("gsettings set org.gnome.system.proxy.http host '127.0.0.1'");
    runCommand("gsettings set org.gnome.system.proxy.http port " + std::to_string(port));
    runCommand("gsettings set org.gnome.system.proxy.https host '127.0.0.1'");
    runCommand("gsettings set org.gnome.system.proxy.https port " + std::to_string(port));
    runCommand("gsettings set org.gnome.system.proxy mode 'manual'");
    m_enabled = true;

    // Start dedicated watchdog daemon (mirrors macOS ReqlyHelper / ProxyGuard.swift)
    ProxyGuard::startWatchdog(getpid(), port);

    return true;
}

bool LinuxSystemProxy::disable() {
    if (!m_enabled) return true;
    ProxyGuard::stopWatchdog();
    if (m_prevMode.find("none") != std::string::npos || m_prevMode.empty()) {
        runCommand("gsettings set org.gnome.system.proxy mode 'none'");
    } else {
        runCommand("gsettings set org.gnome.system.proxy mode " + m_prevMode);
    }
    ProxyGuard::restoreProxyDirect();
    m_enabled = false;
    return true;
}
}
