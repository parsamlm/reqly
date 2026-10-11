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
