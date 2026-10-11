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
