#pragma once
#include "storage.hpp"
#include "proxy_server.hpp"
#include "system_proxy.hpp"

namespace reqly {
class CliRunner {
public:
    CliRunner(TrafficStorage& s, ProxyServer& p, LinuxSystemProxy& sp);
    int run();
private:
    TrafficStorage& m_storage;
    ProxyServer& m_proxy;
    LinuxSystemProxy& m_sysProxy;
};
}
