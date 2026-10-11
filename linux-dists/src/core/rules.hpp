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
