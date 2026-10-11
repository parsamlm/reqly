#include "proxy_guard.hpp"
#include <iostream>
#include <fstream>
#include <sstream>
#include <cstdlib>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <pwd.h>
#include <dirent.h>

namespace reqly {

int ProxyGuard::s_pipeWriteFd = -1;
pid_t ProxyGuard::s_guardPid = -1;

static const char* STATE_FILE_PATH = "/tmp/reqly-proxy-state.json";

void ProxyGuard::executeProxyReset() {
    // 1. Direct gsettings reset
    system("gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null");

    // 2. If running under sudo, reset for logged-in desktop user
    const char* sudoUser = getenv("SUDO_USER");
    const char* sudoUid = getenv("SUDO_UID");
    if (sudoUser && sudoUid) {
        std::string cmd = "su - " + std::string(sudoUser) +
                          " -c 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/" + std::string(sudoUid) +
                          "/bus gsettings set org.gnome.system.proxy mode \"none\"' 2>/dev/null";
        system(cmd.c_str());
    }

    // 3. Scan all active desktop user sessions under /run/user
    DIR* dir = opendir("/run/user");
    if (dir) {
        struct dirent* entry;
        while ((entry = readdir(dir)) != nullptr) {
            std::string name = entry->d_name;
            if (name == "." || name == "..") continue;
            char* end = nullptr;
            long uid = strtol(name.c_str(), &end, 10);
            if (end && *end == '\0' && uid >= 1000) {
                struct passwd* pw = getpwuid(static_cast<uid_t>(uid));
                if (pw && pw->pw_name) {
                    std::string cmd = "su - " + std::string(pw->pw_name) +
                                      " -c 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/" + name +
                                      "/bus gsettings set org.gnome.system.proxy mode \"none\"' 2>/dev/null";
                    system(cmd.c_str());
                }
            }
        }
        closedir(dir);
    }
}

void ProxyGuard::restoreProxyDirect() {
    executeProxyReset();
    unlink(STATE_FILE_PATH);
}

void ProxyGuard::recoverAtLaunch() {
    std::ifstream f(STATE_FILE_PATH);
    if (!f.is_open()) return;

    std::string line;
    pid_t savedPid = 0;
    while (std::getline(f, line)) {
        auto pos = line.find("\"pid\":");
        if (pos != std::string::npos) {
            try {
                savedPid = std::stoi(line.substr(pos + 6));
            } catch (...) {}
        }
    }
    f.close();

    bool isAlive = false;
    if (savedPid > 0) {
        if (kill(savedPid, 0) == 0) {
            std::string cmdPath = "/proc/" + std::to_string(savedPid) + "/cmdline";
            std::ifstream cmdFile(cmdPath);
            if (cmdFile.is_open()) {
                std::string cmdline;
                std::getline(cmdFile, cmdline);
                if (cmdline.find("reqly") != std::string::npos && savedPid != getpid()) {
                    isAlive = true;
                }
            }
        }
    }

    if (!isAlive) {
        std::cerr << "[ProxyGuard] Detected stale proxy settings from previous ungraceful exit (PID "
                  << savedPid << "). Restoring system proxy to none...\n";
        restoreProxyDirect();
    }
}

bool ProxyGuard::startWatchdog(pid_t parentPid, int proxyPort) {
    std::ofstream out(STATE_FILE_PATH);
    if (out.is_open()) {
        out << "{\n"
            << "  \"pid\": " << parentPid << ",\n"
            << "  \"port\": " << proxyPort << ",\n"
            << "  \"active\": true\n"
            << "}\n";
        out.close();
    }

    int pipeFds[2];
    if (pipe(pipeFds) < 0) return false;

    pid_t pid = fork();
    if (pid < 0) {
        close(pipeFds[0]);
        close(pipeFds[1]);
        return false;
    }

    if (pid == 0) {
        close(pipeFds[1]);
        setsid();

        int nullFd = open("/dev/null", O_RDWR);
        if (nullFd >= 0) {
            dup2(nullFd, STDIN_FILENO);
            close(nullFd);
        }

        std::string readFdStr = std::to_string(pipeFds[0]);
        std::string pidStr = std::to_string(parentPid);
        std::string portStr = std::to_string(proxyPort);

        execl("/opt/reqly/bin/reqly-guard", "reqly-guard", "--watch", readFdStr.c_str(), pidStr.c_str(), portStr.c_str(), nullptr);
        execlp("reqly-guard", "reqly-guard", "--watch", readFdStr.c_str(), pidStr.c_str(), portStr.c_str(), nullptr);

        // Fallback watchdog loop if binary not yet in PATH
        char buf[64];
        ssize_t n = read(pipeFds[0], buf, sizeof(buf));
        (void)n;
        executeProxyReset();
        unlink(STATE_FILE_PATH);
        _exit(0);
    }

    close(pipeFds[0]);
    s_pipeWriteFd = pipeFds[1];
    s_guardPid = pid;
    return true;
}

void ProxyGuard::stopWatchdog() {
    if (s_pipeWriteFd >= 0) {
        const char msg[] = "CLEAN_STOP\n";
        (void)write(s_pipeWriteFd, msg, sizeof(msg) - 1);
        close(s_pipeWriteFd);
        s_pipeWriteFd = -1;
    }
    unlink(STATE_FILE_PATH);
}

} // namespace reqly
