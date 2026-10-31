#define _GNU_SOURCE
#include "CGtkShim.h"

#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

// One marshaller for every closure: the call Swift gave rides along as the meta marshal's data.
static void marshal(GClosure *closure, GValue *result, guint count, const GValue *params, gpointer hint,
                    gpointer call) {
    (void) hint;
    ((ReqlyClosureCall) call)(closure->data, result, count, params);
}

GClosure *reqly_closure_new(gpointer context, ReqlyClosureCall call, GDestroyNotify release) {
    GClosure *closure = g_closure_new_simple(sizeof(GClosure), context);
    g_closure_set_meta_marshal(closure, (gpointer) call, marshal);
    // The context goes with the notifier itself: while GLib runs finalize notifiers, it puts each
    // notifier's own data in closure->data. A GDestroyNotify takes that data as its one parameter,
    // as GLib's own code casts them.
    g_closure_add_finalize_notifier(closure, context, (GClosureNotify) (void (*)(void)) release);
    return closure;
}

// libdispatch's hooks for a run loop that isn't its own, which Foundation's RunLoop uses too: the
// main queue rings an eventfd when it has work, and the callback runs the work, on the main thread.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *message);

typedef struct {
    GSource source;
    int fd;
} MainQueueSource;

static gboolean run_main_queue(GSource *source, GSourceFunc callback, gpointer data) {
    (void) callback;
    (void) data;
    uint64_t rings;
    // Quiet the eventfd first, so work queued while this runs rings it again.
    if (read(((MainQueueSource *) source)->fd, &rings, sizeof rings) < 0) {
        // Nothing was waiting: another wake-up already took it.
    }
    _dispatch_main_queue_callback_4CF(NULL);
    return G_SOURCE_CONTINUE;
}

// With no prepare or check, GLib runs the source whenever its file descriptor is readable.
static GSourceFuncs main_queue_funcs = {NULL, NULL, run_main_queue, NULL, NULL, NULL};

guint reqly_attach_main_queue(gint priority) {
    GSource *source = g_source_new(&main_queue_funcs, sizeof(MainQueueSource));
    MainQueueSource *queue = (MainQueueSource *) source;
    queue->fd = _dispatch_get_main_queue_handle_4CF();
    g_source_add_unix_fd(source, queue->fd, G_IO_IN);
    g_source_set_priority(source, priority);
    g_source_set_name(source, "Swift's main queue");
    guint id = g_source_attach(source, NULL);
    g_source_unref(source);
    return id;
}

GType reqly_type_boolean(void) { return G_TYPE_BOOLEAN; }
GType reqly_type_int(void) { return G_TYPE_INT; }
GType reqly_type_uint(void) { return G_TYPE_UINT; }
GType reqly_type_double(void) { return G_TYPE_DOUBLE; }
GType reqly_type_string(void) { return G_TYPE_STRING; }

void reqly_accessible_set_label(GtkWidget *widget, const char *label) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

gboolean reqly_is_main_thread(void) { return gettid() == getpid(); }

const gchar *reqly_type_name(gpointer object) { return G_OBJECT_TYPE_NAME(object); }

void reqly_line_buffered_stdout(void) { setvbuf(stdout, NULL, _IOLBF, 0); }
