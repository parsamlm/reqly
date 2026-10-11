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
