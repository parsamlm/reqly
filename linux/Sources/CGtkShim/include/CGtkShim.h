// What Swift can't write itself on top of GTK's C API: GObject's macros as functions, one
// marshaller that hands every signal to Swift, and the hook that runs Swift's main queue, and with
// it the main actor, from GLib's main loop.

#ifndef CGTKSHIM_H
#define CGTKSHIM_H

#include <adwaita.h>

/// Swift's side of a closure: called with the closure's context, its return value (NULL when the
/// signal returns nothing) and its parameters, the first of them the instance.
typedef void (*ReqlyClosureCall)(gpointer context, GValue *result, guint count, const GValue *params);

/// A closure that calls `call` with `context`, and `release` with it once GLib is done with it.
GClosure *reqly_closure_new(gpointer context, ReqlyClosureCall call, GDestroyNotify release);

/// Runs Swift's main queue whenever it has work, from the thread's default GLib main context, at
/// `priority`. Call once, on the main thread, before the main loop runs.
guint reqly_attach_main_queue(gint priority);

/// Fundamental types, which GLib names with macros.
GType reqly_type_boolean(void);
GType reqly_type_int(void);
GType reqly_type_uint(void);
GType reqly_type_int64(void);
GType reqly_type_double(void);
GType reqly_type_string(void);
GType reqly_type_object(void);
GType reqly_type_variant(void);

/// G_OBJECT_TYPE: an object's own type.
GType reqly_object_type(gpointer object);

/// gtk_accessible_update_property for a widget's label, which C passes as variadic arguments.
void reqly_accessible_set_label(GtkWidget *widget, const char *label);

/// gtk_accessible_update_relation for a relation to `count` widgets, such as labelled-by, in the
/// form the running GTK takes: GTK 4.14's GList, or a newer one's GtkAccessibleList.
void reqly_accessible_set_relation_list(GtkWidget *widget, GtkAccessibleRelation relation, GtkWidget *const *widgets,
                                        guint count);

/// g_signal_emit_by_name for a signal with no parameters that returns nothing, such as a button's
/// "clicked", which C passes as variadic arguments.
void reqly_emit(gpointer instance, const char *signal);

/// A list of the numbers from 0 to `count` less one, each a GtkStringObject of its digits, made
/// only as a list view asks for it, for lists too long to hold an object for each row (numbers.c).
GListModel *reqly_numbers_new(guint count);

/// Makes the list `count` long, adding or taking numbers at its end.
void reqly_numbers_set_count(GListModel *numbers, guint count);

/// Whether this is the process's main thread: its thread ID is the process's.
gboolean reqly_is_main_thread(void);

/// G_OBJECT_TYPE_NAME.
const gchar *reqly_type_name(gpointer object);

/// Standard output a line at a time. Swift 6 won't touch C's stdout, a global it can't check.
void reqly_line_buffered_stdout(void);

#endif
