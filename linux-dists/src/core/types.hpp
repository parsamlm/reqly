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
