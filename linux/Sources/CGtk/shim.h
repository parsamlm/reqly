// GTK 4 and libadwaita, with GLib, GObject and GIO, as one module, so the headers they share are
// imported once. Only the floor's: GTK 4.14 and libadwaita 1.5, on Ubuntu 24.04, where the app is
// built. Anything newer is looked up as the app runs (GtkBinding's Newer.swift). Linked through
// pkg-config's libadwaita-1.
#include <adwaita.h>
#include <glib-unix.h>
