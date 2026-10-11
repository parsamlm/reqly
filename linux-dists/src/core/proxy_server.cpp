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
