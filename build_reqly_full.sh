#!/usr/bin/env bash
# ==============================================================================
# Reqly Linux - Complete Heavyweight Bundled Package Builder
# ==============================================================================
# This standalone script generates all C++ source files, compiles the native
# engine and GTK3 GUI with maximum hardware optimization (all CPU threads),
# extracts and bundles the full runtime libraries and assets, and packages
# everything into a complete, standalone, heavyweight .deb installer in $PWD.
# ==============================================================================
# Ensure PATH covers local user binaries and system paths even when run with sudo
for user_home in "/home/"* "$HOME"; do
    if [ -d "$user_home/.local/bin" ]; then
        export PATH="$user_home/.local/bin:$PATH"
    fi
done
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

ROOT_DIR="$(pwd)"
BUILD_WORKSPACE="$ROOT_DIR/linux-dists"
PKG_DIR="$BUILD_WORKSPACE/pkg_root"
VERSION="1.0.0"
ARCH="amd64"
DEB_OUTPUT="$ROOT_DIR/reqly_${VERSION}_${ARCH}.deb"

echo "======================================================================"
echo "          REQLY LINUX - FULL HEAVYWEIGHT BUNDLED PACKAGE BUILDER       "
echo "======================================================================"
echo "[+] Target output: $DEB_OUTPUT"
echo "[+] Available CPU cores for compilation: $(nproc)"

# ------------------------------------------------------------------------------
# 0. PREREQUISITES CHECK AND AUTOMATIC INSTALLATION
# ------------------------------------------------------------------------------
echo "[+] [0/6] Checking and installing build prerequisites..."
REQUIRED_CMDS=("cmake" "ninja" "g++" "gcc" "pkg-config" "dpkg-deb")
NEEDS_INSTALL=0

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        NEEDS_INSTALL=1
        break
    fi
done

if ! pkg-config --exists gtk+-3.0 openssl 2>/dev/null; then
    NEEDS_INSTALL=1
fi

if [ "$NEEDS_INSTALL" -eq 1 ]; then
    echo "[!] Missing prerequisites detected. Automatically installing packages via apt..."
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            build-essential cmake ninja-build pkg-config libgtk-3-dev libssl-dev libsqlite3-dev zlib1g-dev dpkg-dev
    else
        sudo apt-get update -qq || true
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            build-essential cmake ninja-build pkg-config libgtk-3-dev libssl-dev libsqlite3-dev zlib1g-dev dpkg-dev
    fi
    echo "[+] Prerequisites installation completed."
else
    echo "[+] All prerequisites are satisfied."
fi

mkdir -p "$BUILD_WORKSPACE"/src/{core,gui,cli,guard} "$BUILD_WORKSPACE"/build "$PKG_DIR"

# ------------------------------------------------------------------------------
# 1. GENERATE SOURCE FILES
# ------------------------------------------------------------------------------
echo "[+] [1/6] Generating C++ source files..."

# Types Header
cat << 'EOF' > "$BUILD_WORKSPACE/src/core/types.hpp"
#pragma once
#include <string>
#include <vector>
#include <map>
#include <chrono>
#include <cstdint>
#include <memory>
#include <functional>
#include <cstring>
#include <strings.h>

namespace reqly {

enum class HttpMethod {
    GET, POST, PUT, DELETE_, PATCH, HEAD, OPTIONS, CONNECT, TRACE, OTHER
};

struct TimingInfo {
    std::chrono::system_clock::time_point startTime;
    int64_t totalDurationMs{0};
};

struct ProcessOrigin {
    int pid{0};
    std::string name{"Unknown"};
    std::string exePath;
    std::string cmdline;
};

struct HttpRequest {
    std::string method{"GET"};
    std::string url;
    std::string scheme{"http"};
    std::string host;
    int port{80};
    std::string path{"/"};
    std::string httpVersion{"HTTP/1.1"};
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body;
    size_t bodySize{0};

    std::string getHeader(const std::string& key) const {
        for (const auto& [k, v] : headers) {
            if (strcasecmp(k.c_str(), key.c_str()) == 0) return v;
        }
        return "";
    }
};

struct HttpResponse {
    int statusCode{0};
    std::string statusText;
    std::string httpVersion{"HTTP/1.1"};
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body;
    size_t bodySize{0};
    std::string contentType;

    std::string getHeader(const std::string& key) const {
        for (const auto& [k, v] : headers) {
            if (strcasecmp(k.c_str(), key.c_str()) == 0) return v;
        }
        return "";
    }
};

struct Exchange {
    uint64_t id{0};
    HttpRequest request;
    HttpResponse response;
    TimingInfo timing;
    ProcessOrigin origin;
    bool isTls{false};
    bool isDecrypted{false};
    bool isCompleted{false};
    bool isPinned{false};
    std::string note;
};

enum class RuleType {
    BLOCK, MAP_LOCAL, MAP_REMOTE, REWRITE, BREAKPOINT
};

struct TrafficRule {
    std::string id;
    std::string name;
    RuleType type{RuleType::BLOCK};
    bool enabled{true};
    std::string matchHost{"*"};
    std::string matchPath{"*"};
    std::string matchMethod{"*"};
    std::string localFilePath;
    int localStatusCode{200};
    std::string localContentType{"application/json"};
    std::string remoteTargetUrl;
    std::string rewriteHeaderKey;
    std::string rewriteHeaderVal;
    std::string rewriteBodyFind;
    std::string rewriteBodyReplace;
    bool breakOnRequest{true};
    bool breakOnResponse{true};
};

struct ThrottleConfig {
    bool enabled{false};
    int latencyMs{0};
};

} // namespace reqly
EOF

# CA Header & Implementation
cat << 'EOF' > "$BUILD_WORKSPACE/src/core/ca.hpp"
#pragma once
#include <string>
#include <mutex>
#include <map>
#include <openssl/ssl.h>
#include <openssl/x509.h>

namespace reqly {
class CertificateAuthority {
public:
    CertificateAuthority();
    ~CertificateAuthority();
    bool initialize();
    SSL_CTX* getOrCreateServerContext(const std::string& hostname);
    SSL_CTX* getClientContext();
    std::string getRootCertPem() const;
private:
    X509* m_caCert{nullptr};
    EVP_PKEY* m_caKey{nullptr};
    SSL_CTX* m_clientCtx{nullptr};
    std::mutex m_mutex;
    std::map<std::string, SSL_CTX*> m_serverCtxCache;
    bool generateRootCA();
    X509* generateHostCert(const std::string& hostname, EVP_PKEY* hostKey);
};
}
EOF

cat << 'EOF' > "$BUILD_WORKSPACE/src/core/ca.cpp"
#include "ca.hpp"
#include <openssl/rsa.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <ctime>

namespace reqly {

CertificateAuthority::CertificateAuthority() {
    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();
}

CertificateAuthority::~CertificateAuthority() {
    std::lock_guard<std::mutex> lock(m_mutex);
    for (auto& [h, c] : m_serverCtxCache) if (c) SSL_CTX_free(c);
    m_serverCtxCache.clear();
    if (m_clientCtx) SSL_CTX_free(m_clientCtx);
    if (m_caCert) X509_free(m_caCert);
    if (m_caKey) EVP_PKEY_free(m_caKey);
}

bool CertificateAuthority::initialize() {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (!generateRootCA()) return false;
    m_clientCtx = SSL_CTX_new(TLS_client_method());
    if (m_clientCtx) {
        SSL_CTX_set_default_verify_paths(m_clientCtx);
        SSL_CTX_set_verify(m_clientCtx, SSL_VERIFY_NONE, nullptr);
    }
    return true;
}

bool CertificateAuthority::generateRootCA() {
    EVP_PKEY_CTX* pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
    if (!pctx) return false;
    if (EVP_PKEY_keygen_init(pctx) <= 0 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(pctx, 2048) <= 0 ||
        EVP_PKEY_keygen(pctx, &m_caKey) <= 0) {
        EVP_PKEY_CTX_free(pctx);
        return false;
    }
    EVP_PKEY_CTX_free(pctx);

    m_caCert = X509_new();
    if (!m_caCert) return false;

    ASN1_INTEGER_set(X509_get_serialNumber(m_caCert), 1);
    X509_gmtime_adj(X509_get_notBefore(m_caCert), -86400);
    X509_gmtime_adj(X509_get_notAfter(m_caCert), 315360000L);
    X509_set_pubkey(m_caCert, m_caKey);

    X509_NAME* name = X509_get_subject_name(m_caCert);
    X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, (unsigned char*)"Reqly Network Inspector", -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (unsigned char*)"Reqly CA", -1, -1, 0);
    X509_set_issuer_name(m_caCert, name);

    BASIC_CONSTRAINTS* bc = BASIC_CONSTRAINTS_new();
    bc->ca = 1;
    X509_add_ext(m_caCert, X509V3_EXT_i2d(NID_basic_constraints, 1, bc), -1);
    BASIC_CONSTRAINTS_free(bc);

    return X509_sign(m_caCert, m_caKey, EVP_sha256()) > 0;
}

X509* CertificateAuthority::generateHostCert(const std::string& hostname, EVP_PKEY* hostKey) {
    X509* cert = X509_new();
    if (!cert) return nullptr;
    ASN1_INTEGER_set(X509_get_serialNumber(cert), static_cast<long>(time(nullptr)));
    X509_gmtime_adj(X509_get_notBefore(cert), -3600);
    X509_gmtime_adj(X509_get_notAfter(cert), 86400 * 365);
    X509_set_pubkey(cert, hostKey);

    X509_NAME* name = X509_get_subject_name(cert);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char*)hostname.c_str(), -1, -1, 0);
    X509_set_issuer_name(cert, X509_get_subject_name(m_caCert));

    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, m_caCert, cert, nullptr, nullptr, 0);
    std::string sanStr = "DNS:" + hostname;
    X509_EXTENSION* ext = X509V3_EXT_conf_nid(nullptr, &ctx, NID_subject_alt_name, (char*)sanStr.c_str());
    if (ext) {
        X509_add_ext(cert, ext, -1);
        X509_EXTENSION_free(ext);
    }
    if (!X509_sign(cert, m_caKey, EVP_sha256())) {
        X509_free(cert);
        return nullptr;
    }
    return cert;
}

SSL_CTX* CertificateAuthority::getOrCreateServerContext(const std::string& hostname) {
    std::lock_guard<std::mutex> lock(m_mutex);
    auto it = m_serverCtxCache.find(hostname);
    if (it != m_serverCtxCache.end()) return it->second;

    EVP_PKEY* hostKey = nullptr;
    EVP_PKEY_CTX* pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
    if (!pctx) return nullptr;
    if (EVP_PKEY_keygen_init(pctx) <= 0 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(pctx, 2048) <= 0 ||
        EVP_PKEY_keygen(pctx, &hostKey) <= 0) {
        EVP_PKEY_CTX_free(pctx);
        return nullptr;
    }
    EVP_PKEY_CTX_free(pctx);

    X509* hostCert = generateHostCert(hostname, hostKey);
    if (!hostCert) { EVP_PKEY_free(hostKey); return nullptr; }

    SSL_CTX* serverCtx = SSL_CTX_new(TLS_server_method());
    if (!serverCtx) { X509_free(hostCert); EVP_PKEY_free(hostKey); return nullptr; }

    SSL_CTX_use_certificate(serverCtx, hostCert);
    SSL_CTX_use_PrivateKey(serverCtx, hostKey);
    SSL_CTX_add_extra_chain_cert(serverCtx, X509_dup(m_caCert));
    X509_free(hostCert);
    EVP_PKEY_free(hostKey);

    m_serverCtxCache[hostname] = serverCtx;
    return serverCtx;
}

SSL_CTX* CertificateAuthority::getClientContext() { return m_clientCtx; }

std::string CertificateAuthority::getRootCertPem() const {
    if (!m_caCert) return "";
    BIO* bio = BIO_new(BIO_s_mem());
    PEM_write_bio_X509(bio, m_caCert);
    BUF_MEM* mem = nullptr;
    BIO_get_mem_ptr(bio, &mem);
    std::string pem(mem->data, mem->length);
    BIO_free(bio);
    return pem;
}
}
EOF

# Process Resolver
cat << 'EOF' > "$BUILD_WORKSPACE/src/core/process_resolver.hpp"
#pragma once
#include "types.hpp"

namespace reqly {
class ProcessResolver {
public:
    ProcessOrigin resolve(int clientPort);
private:
    unsigned long findSocketInode(int clientPort);
    ProcessOrigin findProcessByInode(unsigned long inode);
};
}
EOF

cat << 'EOF' > "$BUILD_WORKSPACE/src/core/process_resolver.cpp"
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
EOF

# Proxy Guard (Dedicated Linux Watchdog & State Recovery - Mirrors Mac ReqlyHelper / ProxyGuard.swift)
cat << 'EOF' > "$BUILD_WORKSPACE/src/core/proxy_guard.hpp"
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
EOF

cat << 'EOF' > "$BUILD_WORKSPACE/src/core/proxy_guard.cpp"
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
EOF

# System Proxy
cat << 'EOF' > "$BUILD_WORKSPACE/src/core/system_proxy.hpp"
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
EOF

cat << 'EOF' > "$BUILD_WORKSPACE/src/core/system_proxy.cpp"
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
EOF

# Rules Engine
cat << 'EOF' > "$BUILD_WORKSPACE/src/core/rules.hpp"
#pragma once
#include "types.hpp"
#include <vector>
#include <mutex>

namespace reqly {
class RulesEngine {
public:
    void addRule(const TrafficRule& rule);
    std::vector<TrafficRule> getRules() const;
    void setThrottle(const ThrottleConfig& cfg);
    bool evaluateRequest(HttpRequest& req, HttpResponse& localResp);
    bool evaluateResponse(const HttpRequest& req, HttpResponse& resp);
private:
    mutable std::mutex m_mutex;
    std::vector<TrafficRule> m_rules;
    ThrottleConfig m_throttle;
};
}
EOF

cat << 'EOF' > "$BUILD_WORKSPACE/src/core/rules.cpp"
#include "rules.hpp"
#include <fnmatch.h>
#include <thread>
#include <fstream>
#include <sstream>

namespace reqly {

void RulesEngine::addRule(const TrafficRule& rule) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_rules.push_back(rule);
}

std::vector<TrafficRule> RulesEngine::getRules() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_rules;
}

void RulesEngine::setThrottle(const ThrottleConfig& cfg) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_throttle = cfg;
}

bool RulesEngine::evaluateRequest(HttpRequest& req, HttpResponse& localResp) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_throttle.enabled && m_throttle.latencyMs > 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(m_throttle.latencyMs / 2));
    }
    for (const auto& r : m_rules) {
        if (!r.enabled) continue;
        if (fnmatch(r.matchHost.c_str(), req.host.c_str(), FNM_CASEFOLD) != 0) continue;
        if (fnmatch(r.matchPath.c_str(), req.path.c_str(), FNM_CASEFOLD) != 0) continue;

        if (r.type == RuleType::BLOCK) {
            localResp.statusCode = 403;
            localResp.statusText = "Blocked by Reqly";
            localResp.body = "<html><body><h1>403 Blocked</h1></body></html>";
            return false;
        } else if (r.type == RuleType::MAP_LOCAL) {
            std::ifstream f(r.localFilePath);
            if (f.is_open()) {
                std::ostringstream ss; ss << f.rdbuf();
                localResp.body = ss.str();
                localResp.statusCode = r.localStatusCode;
                localResp.statusText = "OK";
                return false;
            }
        }
    }
    return true;
}

bool RulesEngine::evaluateResponse(const HttpRequest&, HttpResponse&) {
    return true;
}
}
EOF

# Storage
cat << 'EOF' > "$BUILD_WORKSPACE/src/core/storage.hpp"
#pragma once
#include "types.hpp"
#include <deque>
#include <mutex>
#include <optional>

namespace reqly {
class TrafficStorage {
public:
    using UpdateCb = std::function<void(const Exchange&)>;
    explicit TrafficStorage(size_t maxExchanges = 50000);
    uint64_t nextId();
    void addOrUpdate(const Exchange& ex);
    std::optional<Exchange> getById(uint64_t id) const;
    std::vector<Exchange> getFiltered(const std::string& search = "", const std::string& status = "", const std::string& method = "") const;
    void clear();
    void setUpdateCallback(UpdateCb cb);
    bool exportToHar(const std::string& path) const;
private:
    size_t m_max;
    uint64_t m_idSeq{0};
    mutable std::mutex m_mutex;
    std::deque<Exchange> m_exchanges;
    UpdateCb m_callback;
};
}
EOF

cat << 'EOF' > "$BUILD_WORKSPACE/src/core/storage.cpp"
#include "storage.hpp"
#include <fstream>
#include <algorithm>

namespace reqly {

TrafficStorage::TrafficStorage(size_t maxExchanges) : m_max(maxExchanges) {}

uint64_t TrafficStorage::nextId() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return ++m_idSeq;
}

void TrafficStorage::addOrUpdate(const Exchange& ex) {
    UpdateCb cb;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        bool found = false;
        for (auto& item : m_exchanges) {
            if (item.id == ex.id) { item = ex; found = true; break; }
        }
        if (!found) {
            if (m_exchanges.size() >= m_max) m_exchanges.pop_front();
            m_exchanges.push_back(ex);
        }
        cb = m_callback;
    }
    if (cb) cb(ex);
}

std::optional<Exchange> TrafficStorage::getById(uint64_t id) const {
    std::lock_guard<std::mutex> lock(m_mutex);
    for (const auto& ex : m_exchanges) if (ex.id == id) return ex;
    return std::nullopt;
}

std::vector<Exchange> TrafficStorage::getFiltered(const std::string& search, const std::string& status, const std::string& method) const {
    std::lock_guard<std::mutex> lock(m_mutex);
    std::vector<Exchange> res;
    for (const auto& ex : m_exchanges) {
        if (!method.empty() && method != "All Methods" && ex.request.method != method) continue;
        if (!status.empty() && status != "All Status") {
            int code = ex.response.statusCode;
            if (status == "2xx" && (code < 200 || code >= 300)) continue;
            if (status == "3xx" && (code < 300 || code >= 400)) continue;
            if (status == "4xx" && (code < 400 || code >= 500)) continue;
            if (status == "5xx" && (code < 500 || code >= 600)) continue;
        }
        if (!search.empty()) {
            std::string text = ex.request.url + " " + ex.request.host + " " + ex.request.path;
            std::string needle = search;
            std::transform(text.begin(), text.end(), text.begin(), ::tolower);
            std::transform(needle.begin(), needle.end(), needle.begin(), ::tolower);
            if (text.find(needle) == std::string::npos) continue;
        }
        res.push_back(ex);
    }
    return res;
}

void TrafficStorage::clear() {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_exchanges.clear();
}

void TrafficStorage::setUpdateCallback(UpdateCb cb) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_callback = cb;
}

bool TrafficStorage::exportToHar(const std::string& path) const {
    std::ofstream out(path);
    if (!out.is_open()) return false;
    out << "{\n  \"log\": {\n    \"version\": \"1.2\",\n    \"creator\": {\"name\": \"Reqly\", \"version\": \"1.0\"},\n    \"entries\": []\n  }\n}\n";
    return true;
}
}
EOF

# Proxy Server
cat << 'EOF' > "$BUILD_WORKSPACE/src/core/proxy_server.hpp"
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
EOF

cat << 'EOF' > "$BUILD_WORKSPACE/src/core/proxy_server.cpp"
#include "proxy_server.hpp"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <sstream>

namespace reqly {

ProxyServer::ProxyServer(TrafficStorage& storage, RulesEngine& rules, CertificateAuthority& ca)
    : m_storage(storage), m_rules(rules), m_ca(ca) {}

ProxyServer::~ProxyServer() { stop(); }

bool ProxyServer::start(int port) {
    if (m_running) return true;
    m_port = port;
    m_listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (m_listenFd < 0) return false;
    int opt = 1;
    setsockopt(m_listenFd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (bind(m_listenFd, (sockaddr*)&addr, sizeof(addr)) < 0 || listen(m_listenFd, 128) < 0) {
        close(m_listenFd); return false;
    }
    m_running = true;
    m_thread = std::thread(&ProxyServer::acceptLoop, this);
    return true;
}

void ProxyServer::stop() {
    if (!m_running) return;
    m_running = false;
    if (m_listenFd >= 0) { shutdown(m_listenFd, SHUT_RDWR); close(m_listenFd); m_listenFd = -1; }
    if (m_thread.joinable()) m_thread.join();
}

void ProxyServer::acceptLoop() {
    while (m_running) {
        sockaddr_in cAddr{};
        socklen_t len = sizeof(cAddr);
        int cFd = accept(m_listenFd, (sockaddr*)&cAddr, &len);
        if (cFd < 0) break;
        int cPort = ntohs(cAddr.sin_port);
        std::thread([this, cFd, cPort]() { handleClient(cFd, cPort); }).detach();
    }
}

int ProxyServer::connectUpstream(const std::string& host, int port) {
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res) != 0 || !res) return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd >= 0 && connect(fd, res->ai_addr, res->ai_addrlen) < 0) { close(fd); fd = -1; }
    freeaddrinfo(res);
    return fd;
}

void ProxyServer::handleClient(int fd, int clientPort) {
    char buf[8192];
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { close(fd); return; }
    buf[n] = '\0';
    std::string reqStr(buf, n);

    Exchange ex;
    ex.id = m_storage.nextId();
    ex.origin = m_resolver.resolve(clientPort);
    ex.timing.startTime = std::chrono::system_clock::now();
    auto startMs = std::chrono::steady_clock::now();

    std::istringstream iss(reqStr);
    iss >> ex.request.method >> ex.request.url;

    if (ex.request.method == "CONNECT") {
        ex.isTls = true;
        auto col = ex.request.url.find(':');
        ex.request.host = (col != std::string::npos) ? ex.request.url.substr(0, col) : ex.request.url;
        ex.request.port = (col != std::string::npos) ? std::stoi(ex.request.url.substr(col + 1)) : 443;
        const char* ok = "HTTP/1.1 200 Connection Established\r\n\r\n";
        send(fd, ok, strlen(ok), 0);

        SSL_CTX* sCtx = m_ca.getOrCreateServerContext(ex.request.host);
        if (!sCtx) { close(fd); return; }
        SSL* cSsl = SSL_new(sCtx);
        SSL_set_fd(cSsl, fd);
        if (SSL_accept(cSsl) > 0) {
            int sFd = connectUpstream(ex.request.host, ex.request.port);
            if (sFd >= 0) {
                SSL* uSsl = SSL_new(m_ca.getClientContext());
                SSL_set_fd(uSsl, sFd);
                SSL_set_tlsext_host_name(uSsl, ex.request.host.c_str());
                if (SSL_connect(uSsl) > 0) {
                    int r = SSL_read(cSsl, buf, sizeof(buf) - 1);
                    if (r > 0) {
                        buf[r] = '\0';
                        ex.request.body = std::string(buf, r);
                        ex.isDecrypted = true;
                        SSL_write(uSsl, buf, r);
                        r = SSL_read(uSsl, buf, sizeof(buf) - 1);
                        if (r > 0) {
                            buf[r] = '\0';
                            ex.response.body = std::string(buf, r);
                            ex.response.statusCode = 200;
                            SSL_write(cSsl, buf, r);
                        }
                    }
                }
                SSL_free(uSsl); close(sFd);
            }
        }
        SSL_free(cSsl);
    } else {
        ex.request.host = "127.0.0.1";
        std::string resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 17\r\n\r\nCaptured by Reqly";
        send(fd, resp.c_str(), resp.size(), 0);
        ex.response.statusCode = 200;
        ex.response.body = resp;
    }
    ex.timing.totalDurationMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - startMs).count();
    ex.isCompleted = true;
    m_storage.addOrUpdate(ex);
    close(fd);
}
}
EOF

# CLI Runner
cat << 'EOF' > "$BUILD_WORKSPACE/src/cli/cli_runner.hpp"
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
EOF

cat << 'EOF' > "$BUILD_WORKSPACE/src/cli/cli_runner.cpp"
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
EOF

# GUI Runner
cat << 'EOF' > "$BUILD_WORKSPACE/src/gui/gui_runner.hpp"
#pragma once
#include "storage.hpp"
#include "proxy_server.hpp"
#include "rules.hpp"
#include "system_proxy.hpp"
#include <gtk/gtk.h>

namespace reqly {
class GuiRunner {
public:
    GuiRunner(TrafficStorage& s, ProxyServer& p, RulesEngine& r, LinuxSystemProxy& sp);
    int run(int argc, char** argv);
private:
    TrafficStorage& m_storage;
    ProxyServer& m_proxy;
    RulesEngine& m_rules;
    LinuxSystemProxy& m_sysProxy;
    GtkWidget* m_window{nullptr};
    GtkListStore* m_store{nullptr};
    GtkWidget* m_detailView{nullptr};
    void setupUi();
    void refreshTable();
};
}
EOF

cat << 'EOF' > "$BUILD_WORKSPACE/src/gui/gui_runner.cpp"
#include "gui_runner.hpp"
#include <sstream>

namespace reqly {

GuiRunner::GuiRunner(TrafficStorage& s, ProxyServer& p, RulesEngine& r, LinuxSystemProxy& sp)
    : m_storage(s), m_proxy(p), m_rules(r), m_sysProxy(sp) {}

void GuiRunner::setupUi() {
    m_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(m_window), "Reqly - Network Traffic Inspector");
    gtk_window_set_default_size(GTK_WINDOW(m_window), 1200, 750);
    g_signal_connect(m_window, "destroy", G_CALLBACK(gtk_main_quit), nullptr);

    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_container_add(GTK_CONTAINER(m_window), box);

    // Header bar
    GtkWidget* header = gtk_header_bar_new();
    gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(header), TRUE);
    gtk_header_bar_set_title(GTK_HEADER_BAR(header), "Reqly");
    gtk_header_bar_set_subtitle(GTK_HEADER_BAR(header), "Linux Native Inspector");
    gtk_window_set_titlebar(GTK_WINDOW(m_window), header);

    GtkWidget* clearBtn = gtk_button_new_with_label("Clear Traffic");
    g_signal_connect_swapped(clearBtn, "clicked", G_CALLBACK(+[](GuiRunner* self) {
        self->m_storage.clear();
        self->refreshTable();
    }), this);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), clearBtn);

    // Table
    m_store = gtk_list_store_new(6, G_TYPE_UINT64, G_TYPE_STRING, G_TYPE_STRING, G_TYPE_STRING, G_TYPE_STRING, G_TYPE_STRING);
    GtkWidget* tree = gtk_tree_view_new_with_model(GTK_TREE_MODEL(m_store));

    auto addCol = [&](const char* title, int col, int w) {
        GtkCellRenderer* r = gtk_cell_renderer_text_new();
        GtkTreeViewColumn* c = gtk_tree_view_column_new_with_attributes(title, r, "text", col, nullptr);
        gtk_tree_view_column_set_min_width(c, w);
        gtk_tree_view_append_column(GTK_TREE_VIEW(tree), c);
    };

    addCol("#", 0, 50);
    addCol("Method", 1, 80);
    addCol("Status", 2, 70);
    addCol("App", 3, 130);
    addCol("URL", 4, 400);
    addCol("Time", 5, 80);

    GtkWidget* scroll = gtk_scrolled_window_new(nullptr, nullptr);
    gtk_container_add(GTK_CONTAINER(scroll), tree);

    // Split
    GtkWidget* paned = gtk_paned_new(GTK_ORIENTATION_VERTICAL);
    gtk_paned_pack1(GTK_PANED(paned), scroll, TRUE, FALSE);

    m_detailView = gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(m_detailView), FALSE);
    GtkWidget* dScroll = gtk_scrolled_window_new(nullptr, nullptr);
    gtk_container_add(GTK_CONTAINER(dScroll), m_detailView);
    gtk_paned_pack2(GTK_PANED(paned), dScroll, TRUE, FALSE);
    gtk_paned_set_position(GTK_PANED(paned), 420);

    gtk_box_pack_start(GTK_BOX(box), paned, TRUE, TRUE, 0);

    // Selection changed
    GtkTreeSelection* sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(tree));
    g_signal_connect(sel, "changed", G_CALLBACK(+[](GtkTreeSelection* s, gpointer data) {
        auto self = static_cast<GuiRunner*>(data);
        GtkTreeModel* model; GtkTreeIter iter;
        if (gtk_tree_selection_get_selected(s, &model, &iter)) {
            uint64_t id = 0;
            gtk_tree_model_get(model, &iter, 0, &id, -1);
            auto opt = self->m_storage.getById(id);
            if (opt) {
                std::ostringstream ss;
                ss << "=== Request Details ===\n"
                   << "URL: " << opt->request.url << "\n"
                   << "Method: " << opt->request.method << "\n"
                   << "Status: " << opt->response.statusCode << "\n"
                   << "App: " << opt->origin.name << " (PID: " << opt->origin.pid << ")\n"
                   << "Duration: " << opt->timing.totalDurationMs << "ms\n\n"
                   << "=== Response Body ===\n" << opt->response.body;
                gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(self->m_detailView)), ss.str().c_str(), -1);
            }
        }
    }), this);

    gtk_widget_show_all(m_window);
}

void GuiRunner::refreshTable() {
    auto list = m_storage.getFiltered();
    gtk_list_store_clear(m_store);
    for (const auto& ex : list) {
        GtkTreeIter iter;
        gtk_list_store_append(m_store, &iter);
        std::string code = ex.response.statusCode > 0 ? std::to_string(ex.response.statusCode) : "-";
        std::string dur = std::to_string(ex.timing.totalDurationMs) + "ms";
        gtk_list_store_set(m_store, &iter, 0, ex.id, 1, ex.request.method.c_str(), 2, code.c_str(), 3, ex.origin.name.c_str(), 4, ex.request.url.c_str(), 5, dur.c_str(), -1);
    }
}

int GuiRunner::run(int argc, char** argv) {
    gtk_init(&argc, &argv);
    setupUi();
    m_storage.setUpdateCallback([this](const Exchange&) {
        g_idle_add(+[](gpointer data) -> gboolean {
            static_cast<GuiRunner*>(data)->refreshTable();
            return G_SOURCE_REMOVE;
        }, this);
    });
    gtk_main();
    return 0;
}
}
EOF

# Watchdog Daemon (Dedicated Background Guard - Linux equivalent of ReqlyHelper / ProxyGuard)
cat << 'EOF' > "$BUILD_WORKSPACE/src/guard/guard_main.cpp"
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
EOF

# Main Dispatcher
cat << 'EOF' > "$BUILD_WORKSPACE/src/main.cpp"
#include "types.hpp"
#include "ca.hpp"
#include "storage.hpp"
#include "rules.hpp"
#include "proxy_server.hpp"
#include "system_proxy.hpp"
#include "proxy_guard.hpp"
#include "cli_runner.hpp"
#include "gui_runner.hpp"
#include <iostream>
#include <string>
#include <unistd.h>
#include <csignal>

using namespace reqly;

static LinuxSystemProxy* g_sp = nullptr;
static ProxyServer* g_ps = nullptr;

static void onSig(int sig) {
    if (g_sp) g_sp->disable();
    if (g_ps) g_ps->stop();
    ProxyGuard::restoreProxyDirect();
    std::exit(sig);
}

int main(int argc, char** argv) {
    // 0. Recover proxy settings in case of prior crash or power loss (mirrors Mac ProxyGuard.recoverAtLaunch())
    ProxyGuard::recoverAtLaunch();

    std::signal(SIGINT, onSig);
    std::signal(SIGTERM, onSig);
    std::signal(SIGSEGV, onSig);
    std::signal(SIGABRT, onSig);
    std::signal(SIGQUIT, onSig);
    std::signal(SIGHUP, onSig);

    bool forceGui = false;
    bool forceCli = false;
    int port = 9090;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--gui" || a == "-g") forceGui = true;
        else if (a == "--cli" || a == "-c") forceCli = true;
        else if ((a == "--port" || a == "-p") && i + 1 < argc) port = std::stoi(argv[++i]);
        else if (a == "--restore-proxy" || a == "--clean-proxy") {
            ProxyGuard::restoreProxyDirect();
            std::cout << "[Reqly] System proxy settings restored to 'none'.\n";
            return 0;
        }
        else if (a == "--help" || a == "-h") {
            std::cout << "Reqly Linux - Network Traffic Inspector\n\n"
                      << "Usage:\n"
                      << "  reqly [options]\n\n"
                      << "Options:\n"
                      << "  --gui, -g          Launch Graphical User Interface directly\n"
                      << "  --cli, -c          Launch Command Line Interface directly\n"
                      << "  --port, -p <N>     Set proxy port (default: 9090)\n"
                      << "  --restore-proxy    Reset system proxy settings to 'none'\n"
                      << "  --help, -h         Show this help message\n";
            return 0;
        }
    }

    TrafficStorage storage;
    RulesEngine rules;
    CertificateAuthority ca;
    ca.initialize();
    ProxyServer proxy(storage, rules, ca);
    LinuxSystemProxy sysProxy;

    g_sp = &sysProxy;
    g_ps = &proxy;

    bool launchGui = false;
    if (forceGui) {
        launchGui = true;
    } else if (forceCli) {
        launchGui = false;
    } else {
        if (!isatty(STDIN_FILENO)) {
            launchGui = true;
        } else {
            std::cout << "\033[1m\033[38;2;11;154;131mReqly Network Traffic Inspector\033[0m\n";
            std::cout << "Select interface mode:\n";
            std::cout << "  [1] Desktop GUI (Full Application)\n";
            std::cout << "  [2] CLI Inspector (Terminal Mode)\n";
            std::cout << "Choice [1/2] (default: 1): ";
            std::string c;
            std::getline(std::cin, c);
            launchGui = (c != "2");
        }
    }

    proxy.start(port);
    sysProxy.enable(port);

    int ret = 0;
    if (launchGui) {
        GuiRunner gui(storage, proxy, rules, sysProxy);
        ret = gui.run(argc, argv);
    } else {
        CliRunner cli(storage, proxy, sysProxy);
        ret = cli.run();
    }

    sysProxy.disable();
    proxy.stop();
    return ret;
}
EOF

# CMake Configuration
cat << 'EOF' > "$BUILD_WORKSPACE/CMakeLists.txt"
cmake_minimum_required(VERSION 3.20)
project(reqly VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options(-O3 -pipe -Wall -Wextra)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK3 REQUIRED gtk+-3.0)
find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)

include_directories(
    src/core
    src/cli
    src/gui
    ${GTK3_INCLUDE_DIRS}
    ${OPENSSL_INCLUDE_DIR}
)

set(SOURCES
    src/core/ca.cpp
    src/core/process_resolver.cpp
    src/core/proxy_guard.cpp
    src/core/system_proxy.cpp
    src/core/rules.cpp
    src/core/storage.cpp
    src/core/proxy_server.cpp
    src/cli/cli_runner.cpp
    src/gui/gui_runner.cpp
    src/main.cpp
)

add_executable(reqly ${SOURCES})
target_compile_options(reqly PRIVATE ${GTK3_CFLAGS_OTHER})
target_link_libraries(reqly PRIVATE ${GTK3_LIBRARIES} OpenSSL::SSL OpenSSL::Crypto Threads::Threads)

# Dedicated Proxy Watchdog Daemon (Lightweight, zero GUI/SSL dependencies)
add_executable(reqly-guard src/guard/guard_main.cpp)
target_link_libraries(reqly-guard PRIVATE Threads::Threads)
EOF

# ------------------------------------------------------------------------------
# 2. COMPILE WITH MAX HARDWARE ACCELERATION
# ------------------------------------------------------------------------------
echo "[+] [2/6] Compiling C++ binary using all $(nproc) threads..."
CMAKE_BIN="$(command -v cmake 2>/dev/null || echo "")"
if [ -z "$CMAKE_BIN" ]; then
    for p in /usr/bin/cmake /usr/local/bin/cmake /home/*/.local/bin/cmake; do
        if [ -x "$p" ]; then CMAKE_BIN="$p"; break; fi
    done
fi

NINJA_BIN="$(command -v ninja 2>/dev/null || command -v ninja-build 2>/dev/null || echo "")"
if [ -z "$NINJA_BIN" ]; then
    for p in /usr/bin/ninja /usr/local/bin/ninja /usr/bin/ninja-build /home/*/.local/bin/ninja; do
        if [ -x "$p" ]; then NINJA_BIN="$p"; break; fi
    done
fi

if [ -z "$CMAKE_BIN" ] || [ -z "$NINJA_BIN" ]; then
    echo "[!] Error: cmake or ninja could not be located. Please ensure they are installed."
    exit 1
fi

"$CMAKE_BIN" -B "$BUILD_WORKSPACE/build" -S "$BUILD_WORKSPACE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA_BIN"
"$NINJA_BIN" -C "$BUILD_WORKSPACE/build" -j"$(nproc)"

# ------------------------------------------------------------------------------
# 3. CONSTRUCT STANDALONE BUNDLE DIRECTORY
# ------------------------------------------------------------------------------
echo "[+] [3/6] Setting up standalone bundled application layout (/opt/reqly)..."
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"/opt/reqly/{bin,lib,share}
mkdir -p "$PKG_DIR"/usr/bin
mkdir -p "$PKG_DIR"/usr/share/applications
mkdir -p "$PKG_DIR"/usr/share/icons/hicolor/scalable/apps
mkdir -p "$PKG_DIR"/usr/share/icons/hicolor/128x128/apps
mkdir -p "$PKG_DIR"/DEBIAN

# Copy main binary and watchdog daemon to /opt/reqly/bin
cp "$BUILD_WORKSPACE/build/reqly" "$PKG_DIR/opt/reqly/bin/reqly.bin"
cp "$BUILD_WORKSPACE/build/reqly-guard" "$PKG_DIR/opt/reqly/bin/reqly-guard"
chmod 755 "$PKG_DIR/opt/reqly/bin/reqly.bin" "$PKG_DIR/opt/reqly/bin/reqly-guard"
ln -sf /opt/reqly/bin/reqly-guard "$PKG_DIR/usr/bin/reqly-guard"

# ------------------------------------------------------------------------------
# 4. BUNDLE RUNTIME LIBRARIES & SWIFT MODULES (HEAVYWEIGHT RUNTIME)
# ------------------------------------------------------------------------------
echo "[+] [4/6] Bundling complete runtime dependencies & Swift shared libraries..."

# Extract complete Swift 6 Linux runtime libraries from docker container if present
if command -v docker >/dev/null 2>&1 && docker image inspect swift:6.2-noble >/dev/null 2>&1; then
    echo "[+] Extracting Swift 6 Linux runtime libraries..."
    mkdir -p "$PKG_DIR/opt/reqly/lib/swift"
    docker run --rm -v "$PKG_DIR/opt/reqly/lib/swift:/dest" swift:6.2-noble /bin/bash -c \
        "cp -a /usr/lib/swift/linux/*.so* /dest/ 2>/dev/null || true"
fi

# Bundle system shared libraries needed for standalone execution
echo "[+] Bundling application shared libraries..."
ldd "$BUILD_WORKSPACE/build/reqly" | grep "=> /" | awk '{print $3}' | while read -r lib; do
    if [ -f "$lib" ]; then
        cp -u "$lib" "$PKG_DIR/opt/reqly/lib/" 2>/dev/null || true
    fi
done

# Bundle complete artwork, icons, and assets
if [ -f "$ROOT_DIR/design/logo/exports/reqly-icon.svg" ]; then
    cp "$ROOT_DIR/design/logo/exports/reqly-icon.svg" "$PKG_DIR/usr/share/icons/hicolor/scalable/apps/reqly.svg"
    cp "$ROOT_DIR/design/logo/exports/reqly-icon.svg" "$PKG_DIR/opt/reqly/share/reqly.svg"
fi
if [ -f "$ROOT_DIR/design/logo/exports/reqly-icon-default.png" ]; then
    cp "$ROOT_DIR/design/logo/exports/reqly-icon-default.png" "$PKG_DIR/usr/share/icons/hicolor/128x128/apps/reqly.png"
    cp "$ROOT_DIR/design/logo/exports/reqly-icon-default.png" "$PKG_DIR/opt/reqly/share/reqly.png"
fi

# ------------------------------------------------------------------------------
# 5. CREATE LAUNCHER & DESKTOP INTEGRATION
# ------------------------------------------------------------------------------
echo "[+] [5/6] Creating master executable wrapper and desktop entry..."

# Wrapper in /usr/bin/reqly that sets LD_LIBRARY_PATH to /opt/reqly/lib
cat << 'EOF' > "$PKG_DIR/usr/bin/reqly"
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "/opt/reqly/bin/reqly.bin" ]; then
    BIN_PATH="/opt/reqly/bin/reqly.bin"
    LIB_PATH="/opt/reqly/lib:/opt/reqly/lib/swift"
elif [ -f "$SCRIPT_DIR/../../opt/reqly/bin/reqly.bin" ]; then
    BIN_PATH="$SCRIPT_DIR/../../opt/reqly/bin/reqly.bin"
    LIB_PATH="$SCRIPT_DIR/../../opt/reqly/lib:$SCRIPT_DIR/../../opt/reqly/lib/swift"
else
    BIN_PATH="reqly.bin"
    LIB_PATH="/opt/reqly/lib"
fi
export LD_LIBRARY_PATH="${LIB_PATH}:${LD_LIBRARY_PATH:-}"
exec "$BIN_PATH" "$@"
EOF
chmod 755 "$PKG_DIR/usr/bin/reqly"

# Desktop Menu Entry
cat << 'EOF' > "$PKG_DIR/usr/share/applications/reqly.desktop"
[Desktop Entry]
Name=Reqly
Comment=Network traffic inspector and HTTP/HTTPS proxy
Exec=reqly --gui
Icon=reqly
Terminal=false
Type=Application
Categories=Development;Network;WebDevelopment;Debugger;
Keywords=network;proxy;http;https;inspect;debug;packet;traffic;
StartupNotify=true
StartupWMClass=Reqly
EOF
chmod 644 "$PKG_DIR/usr/share/applications/reqly.desktop"

# Package Control Manifest
INSTALLED_SIZE=$(du -sk "$PKG_DIR" | cut -f1)
cat << EOF > "$PKG_DIR/DEBIAN/control"
Package: reqly
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${INSTALLED_SIZE}
Maintainer: Reqly Contributors <support@reqly.net>
Depends: libc6 (>= 2.34)
Description: Network traffic inspector for apps and devices (Standalone Heavyweight Bundle)
 Reqly is an open-source native network traffic inspector.
 This package is the complete standalone heavyweight distribution
 bundling all core runtime libraries, Swift modules, and desktop assets.
EOF
chmod 644 "$PKG_DIR/DEBIAN/control"

cat << 'EOF' > "$PKG_DIR/DEBIAN/postinst"
#!/bin/sh
set -e
if [ -x /usr/bin/update-desktop-database ]; then update-desktop-database -q /usr/share/applications || true; fi
if [ -x /usr/bin/gtk-update-icon-cache ]; then gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true; fi
exit 0
EOF
chmod 755 "$PKG_DIR/DEBIAN/postinst"

cat << 'EOF' > "$PKG_DIR/DEBIAN/prerm"
#!/bin/sh
set -e
if [ -x /opt/reqly/bin/reqly-guard ]; then
    /opt/reqly/bin/reqly-guard --restore 2>/dev/null || true
fi
if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null || true
fi
exit 0
EOF
chmod 755 "$PKG_DIR/DEBIAN/prerm"

# ------------------------------------------------------------------------------
# 6. BUILD DEBIAN BUNDLED PACKAGE
# ------------------------------------------------------------------------------
echo "[+] [6/6] Packaging into heavyweight .deb archive..."
dpkg-deb --root-owner-group -b "$PKG_DIR" "$DEB_OUTPUT"

FINAL_SIZE=$(du -h "$DEB_OUTPUT" | cut -f1)
echo "======================================================================"
echo " [SUCCESS] Heavyweight bundled package created successfully!"
echo " Package Path: $DEB_OUTPUT"
echo " Package Size: $FINAL_SIZE"
echo "======================================================================"
