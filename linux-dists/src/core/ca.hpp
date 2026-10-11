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
