#include "cli_runner.hpp"
#include <iostream>
#include <iomanip>

namespace reqly {
CliRunner::CliRunner(TrafficStorage& s, ProxyServer& p, LinuxSystemProxy& sp)
    : m_storage(s), m_proxy(p), m_sysProxy(sp) {}

int CliRunner::run() {
    std::cout << "\033[1m\033[38;2;11;154;131m=== Reqly Terminal Inspector ===\033[0m\n";
    std::cout << "Listening on 127.0.0.1:" << m_proxy.getPort() << " | Proxy: " << (m_sysProxy.isEnabled() ? "ACTIVE" : "INACTIVE") << "\n";
    std::cout << "Commands: [c] Clear  [q] Quit\n";
    std::cout << "------------------------------------------------------------\n";

    m_storage.setUpdateCallback([](const Exchange& ex) {
        if (!ex.isCompleted) return;
        std::cout << "#" << std::setw(5) << ex.id << " "
                  << std::setw(7) << ex.request.method << " "
                  << std::setw(4) << ex.response.statusCode << " "
                  << std::setw(20) << ex.origin.name << " "
                  << ex.request.url << " (" << ex.timing.totalDurationMs << "ms)\n";
    });

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line == "q" || line == "quit") break;
        if (line == "c" || line == "clear") {
            m_storage.clear();
            std::cout << "Traffic cleared.\n";
        }
    }
    return 0;
}
}
