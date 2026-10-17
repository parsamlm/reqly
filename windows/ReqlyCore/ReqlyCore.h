// ReqlyCore.dll: Reqly's core for the Windows app. The app opens sessions, sends them requests
// and gets events back, all as UTF-8 JSON. The messages are described in
// Sources/CoreInterface/Messages.swift; their version is `interfaceVersion` there.
//
// Threads:
// - Callbacks come on the core's own threads. Copy the text out and return quickly; move work
//   to the app's UI thread yourself.
// - reqly_open, reqly_body and reqly_close wait for the core. Call them from the app's own
//   threads, never from inside a callback, and keep them off the UI thread.
//
// Memory: text handed to a callback lasts only for that call. Bytes from reqly_body are the
// app's to free, with reqly_free.

#ifndef REQLY_CORE_H
#define REQLY_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct reqly_session reqly_session;

/// Receives an event or a reply, and the context the app passed in.
typedef void (*reqly_callback)(const char *json, void *context);

/// Opens a session: `{"sessionsFolder": "C:\\...\\Sessions"}` for a new, live one, plus
/// `"file": "C:\\...\\Saved.reqly"` to open a saved one. A live one can also take
/// `"setsSystemProxy": true` with `"proxyRestoreFile": "C:\\...\\ProxyRestore.json"`,
/// `"findsApps": false`, and `"rootFile": "C:\\...\\Certificate.dat"` to decrypt HTTPS. Its
/// events go to `events`, with `context`, until it's closed. Returns NULL if it can't be opened,
/// after an `openFailed` event that says why.
reqly_session *reqly_open(const char *options, reqly_callback events, void *context);

/// Sends a request, such as `{"call": "startCapturing", "port": 9090}`. The reply, a result or
/// a problem, goes to `done` with `context`. Replies can come in any order: wait for one
/// before a request that depends on it.
void reqly_call(reqly_session *session, const char *request, reqly_callback done, void *context);

/// Part of an exchange's body: `part` is 0 for the request's, 1 for the response's, as they
/// came, or 2 and 3 for them unpacked, as the Hex and Preview views show them. Returns at most
/// `limit` bytes from `offset`, with their number in `length`, or NULL when there's no such
/// exchange.
void *reqly_body(reqly_session *session, uint64_t exchange, int32_t part, int64_t offset, int64_t limit,
                 int64_t *length);

/// Frees what reqly_body returned.
void reqly_free(void *pointer);

/// Puts your user's proxy settings back if a Reqly that quit unexpectedly left them pointing at
/// itself; `restore_file` is the session's `proxyRestoreFile`. Returns 1 if it put them back, 0
/// if there was nothing to do, or -1 if it couldn't. The watcher calls it once Reqly has gone,
/// and the app at launch.
int32_t reqly_restore_proxy(const char *restore_file);

/// Removes Reqly's certificate, as Reqly is uninstalled: from your user's trusted roots, which
/// Windows asks you to confirm, and its key in `root_file`, a session's `rootFile`. With
/// `stand_in`, `root_file` is a test run's `rootStandIn`, which only goes. Returns 1 if it removed
/// it, 0 if there was none, 2 if you said no, or -1 if it couldn't.
int32_t reqly_remove_root(const char *root_file, int32_t stand_in);

/// Stops capturing and closes the session. Its folder goes; a saved file it came from stays.
void reqly_close(reqly_session *session);

/// From now on, when Swift's code stops the process, as a failed check does, writes the crashed
/// thread's stack to the standard error, as Swift's backtracer does, which can't run in a Windows
/// app: every frame, with the modules it went through and their time stamps, to look up with that
/// build's debug information. Then, on the crashed thread, it calls `then`, if it isn't NULL and
/// the stack went through code in no module, such as .NET's, for the app to name those frames
/// itself while it still can. Call it once the standard error goes where the crash should be told.
void reqly_catch_crashes(void (*then)(void));

/// For the app's self-check only: stops the process with `message` as a failed check in the core
/// does, on one of the core's own threads, with Swift's "Fatal error" and its stack, so the next
/// launch has a crash to report. It returns before the crash.
void reqly_crash_for_test(const char *message);

/// As `reqly_crash_for_test`, on the calling thread, such as one of .NET's, which doesn't return.
void reqly_crash_here_for_test(const char *message);

#ifdef __cplusplus
}
#endif

#endif
