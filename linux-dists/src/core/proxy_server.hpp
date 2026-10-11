#pragma once
#include "types.hpp"
#include "ca.hpp"
#include "storage.hpp"
#include "rules.hpp"
#include "process_resolver.hpp"
#include <atomic>
#include <thread>

namespace reqly {
class ProxyServer {
public:
    ProxyServer(TrafficStorage& storage, RulesEngine& rules, CertificateAuthority& ca);
    ~ProxyServer();
    bool start(int port = 9090);
    void stop();
    bool isRunning() const { return m_running; }
    int getPort() const { return m_port; }
private:
    TrafficStorage& m_storage;
    RulesEngine& m_rules;
    CertificateAuthority& m_ca;
    ProcessResolver m_resolver;
    int m_port{9090};
    int m_listenFd{-1};
    std::atomic<bool> m_running{false};
    std::thread m_thread;

    void acceptLoop();
    void handleClient(int fd, int clientPort);
    static int connectUpstream(const std::string& host, int port);
};
}
