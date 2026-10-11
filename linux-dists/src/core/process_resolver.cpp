#include "process_resolver.hpp"
#include <fstream>
#include <sstream>
#include <filesystem>
#include <cctype>

namespace reqly {
namespace fs = std::filesystem;

ProcessOrigin ProcessResolver::resolve(int clientPort) {
    ProcessOrigin origin;
    unsigned long inode = findSocketInode(clientPort);
    if (inode == 0) return origin;
    return findProcessByInode(inode);
}

unsigned long ProcessResolver::findSocketInode(int clientPort) {
    std::ifstream file("/proc/net/tcp");
    if (!file.is_open()) return 0;
    std::string line;
    std::getline(file, line);
    while (std::getline(file, line)) {
        std::istringstream iss(line);
        std::string sl, localAddr, remAddr, st, txRx, tr, tmWhen, retrns;
        int uid, timeout;
        unsigned long inode = 0;
        if (iss >> sl >> localAddr >> remAddr >> st >> txRx >> tr >> tmWhen >> retrns >> uid >> timeout >> inode) {
            auto colon = localAddr.find(':');
            if (colon != std::string::npos) {
                int port = std::stoul(localAddr.substr(colon + 1), nullptr, 16);
                if (port == clientPort) return inode;
            }
        }
    }
    return 0;
}

ProcessOrigin ProcessResolver::findProcessByInode(unsigned long targetInode) {
    ProcessOrigin origin;
    std::string socketTarget = "socket:[" + std::to_string(targetInode) + "]";
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator("/proc", ec)) {
        if (!entry.is_directory()) continue;
        std::string pidStr = entry.path().filename().string();
        if (pidStr.empty() || !std::isdigit(pidStr[0])) continue;
        int pid = std::stoi(pidStr);
        std::string fdDir = "/proc/" + pidStr + "/fd";
        for (const auto& fdEntry : fs::directory_iterator(fdDir, ec)) {
            if (ec) break;
            if (fdEntry.is_symlink()) {
                if (fs::read_symlink(fdEntry.path(), ec).string() == socketTarget) {
                    origin.pid = pid;
                    std::string exe = fs::read_symlink("/proc/" + pidStr + "/exe", ec).string();
                    if (!ec && !exe.empty()) {
                        origin.exePath = exe;
                        origin.name = fs::path(exe).filename().string();
                    }
                    return origin;
                }
            }
        }
    }
    return origin;
}
}
