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
