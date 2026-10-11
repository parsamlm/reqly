#pragma once
#include <string>
#include <sys/types.h>

namespace reqly {

class ProxyGuard {
public:
    static void recoverAtLaunch();
    static bool startWatchdog(pid_t parentPid, int proxyPort);
    static void stopWatchdog();
    static void restoreProxyDirect();

private:
    static int s_pipeWriteFd;
    static pid_t s_guardPid;
    static void executeProxyReset();
};

} // namespace reqly
