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
