#include "CGtkShim.h"

// A list of the numbers from 0, each a GtkStringObject made as a list view asks for it, so a list
// of a million lines, such as a body's hex, costs no more than the rows that show. GTK has no list
// like it, and Swift can't implement a GObject interface itself.

#define REQLY_TYPE_NUMBERS (reqly_numbers_get_type())
G_DECLARE_FINAL_TYPE(ReqlyNumbers, reqly_numbers, REQLY, NUMBERS, GObject)

struct _ReqlyNumbers {
    GObject parent_instance;
    guint count;
};

static GType numbers_item_type(GListModel *list) {
    (void) list;
    return GTK_TYPE_STRING_OBJECT;
}

static guint numbers_count(GListModel *list) { return REQLY_NUMBERS(list)->count; }

static gpointer numbers_item(GListModel *list, guint position) {
    if (position >= REQLY_NUMBERS(list)->count) {
        return NULL;
    }
    char number[16];
    g_snprintf(number, sizeof number, "%u", position);
    return gtk_string_object_new(number);
}

static void reqly_numbers_list_init(GListModelInterface *interface) {
    interface->get_item_type = numbers_item_type;
    interface->get_n_items = numbers_count;
    interface->get_item = numbers_item;
}

G_DEFINE_FINAL_TYPE_WITH_CODE(ReqlyNumbers, reqly_numbers, G_TYPE_OBJECT,
                              G_IMPLEMENT_INTERFACE(G_TYPE_LIST_MODEL, reqly_numbers_list_init))

static void reqly_numbers_class_init(ReqlyNumbersClass *class) { (void) class; }

static void reqly_numbers_init(ReqlyNumbers *numbers) { numbers->count = 0; }

GListModel *reqly_numbers_new(guint count) {
    ReqlyNumbers *numbers = g_object_new(REQLY_TYPE_NUMBERS, NULL);
    numbers->count = count;
    return G_LIST_MODEL(numbers);
}

void reqly_numbers_set_count(GListModel *list, guint count) {
    ReqlyNumbers *numbers = REQLY_NUMBERS(list);
    guint before = numbers->count;
    if (count == before) {
        return;
    }
    numbers->count = count;
    if (count > before) {
        g_list_model_items_changed(list, before, 0, count - before);
    } else {
        g_list_model_items_changed(list, count, before - count, 0);
    }
}
