#pragma once
#include <string>
#include "proxy_guard.hpp"

namespace reqly {
class LinuxSystemProxy {
public:
    ~LinuxSystemProxy();
    bool enable(int port = 9090);
    bool disable();
    bool isEnabled() const { return m_enabled; }
private:
    bool m_enabled{false};
    std::string m_prevMode{"none"};
    static std::string runCommand(const std::string& cmd);
};
}
