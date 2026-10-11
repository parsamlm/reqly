#include <iostream>
#include <string>
#include <cstdlib>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <pwd.h>

static const char* STATE_FILE_PATH = "/tmp/reqly-proxy-state.json";

static void restoreProxy() {
    // 1. Direct gsettings reset
    system("gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null");

    // 2. Sudo user reset
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

    unlink(STATE_FILE_PATH);
}

int main(int argc, char** argv) {
    if (argc > 1 && (std::string(argv[1]) == "--restore" || std::string(argv[1]) == "--clean")) {
        restoreProxy();
        std::cout << "[reqly-guard] System proxy settings restored to 'none'.\n";
        return 0;
    }

    if (argc >= 4 && std::string(argv[1]) == "--watch") {
        int readFd = -1;
        try {
            readFd = std::stoi(argv[2]);
        } catch (...) {
            return 1;
        }

        // Watchdog blocking read: when the parent process exits, crashes, or is killed with kill -9,
        // the kernel automatically closes all file descriptors, causing read() to return immediately.
        char buf[128];
        ssize_t n = read(readFd, buf, sizeof(buf));
        (void)n;
        close(readFd);

        restoreProxy();
        return 0;
    }

    std::cout << "reqly-guard - Dedicated Proxy Watchdog Daemon\n\n"
              << "Usage:\n"
              << "  reqly-guard --restore          Immediately restore system proxy to 'none'\n"
              << "  reqly-guard --watch <fd> <pid> <port>  Watch process pipe and restore proxy on termination\n";
    return 0;
}
