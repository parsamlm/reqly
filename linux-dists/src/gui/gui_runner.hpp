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
