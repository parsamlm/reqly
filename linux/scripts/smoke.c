// check-core.sh's test program. It loads libReqlyCore.so as the app does, opens a live session
// with the stand-in certificate store and without your proxy settings, makes Reqly's certificate,
// captures on 127.0.0.1 and sends one request through Reqly to a server of its own, also on
// 127.0.0.1, and closes the session. It also checks that Swift's runtime came from beside
// libReqlyCore.so, not from a toolchain. It gives up after a minute, so a core that stops
// answering fails the check instead of hanging it.
//   smoke <libReqlyCore.so>           exits 0 when all of that worked
//   smoke <libReqlyCore.so> --crash   stops in the core, as a failed check does, so that
//                                     check-core.sh can look at the crash report
// stage-core.sh builds it with the toolchain's clang, against ReqlyCore.h.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <ftw.h>
#include <libgen.h>
#include <limits.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "ReqlyCore.h"

static __typeof__(&reqly_open) openSession;
static __typeof__(&reqly_call) callSession;
static __typeof__(&reqly_close) closeSession;

// Ends at once, without exit's clean-up, which could wait on the core's threads or the server's.
static void fail(const char *format, ...) {
    fflush(stdout);
    va_list arguments;
    va_start(arguments, format);
    fputs("smoke: ", stderr);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
    _exit(1);
}

// What the test is waiting for, which the message names when it runs out of time.
static const char *volatile waitingFor = "libReqlyCore.so to load";

static void sayTimeIsUp(void) {
    const char *parts[] = {"smoke: gave up after a minute, waiting for ", waitingFor, "\n"};
    for (size_t i = 0; i < sizeof parts / sizeof parts[0]; i++) {
        if (write(STDERR_FILENO, parts[i], strlen(parts[i])) < 0) {
            break;
        }
    }
}

static void onTimeLimit(int signal) {
    (void)signal;
    sayTimeIsUp();
    _exit(1);
}

// While Swift's runtime writes a crash's report, it holds back signals, so the alarm can't end a
// crash whose report never comes. A process of its own ends it instead, and ends with it.
static void limitTheCrash(void) {
    pid_t test = getpid();
    pid_t watcher = fork();
    if (watcher < 0) {
        fail("can't time the crash");
    }
    if (watcher == 0) {
        prctl(PR_SET_PDEATHSIG, SIGKILL);
        if (getppid() == test) {
            sleep(60);
            sayTimeIsUp();
            kill(test, SIGKILL);
        }
        _exit(0);
    }
}

static void *symbol(void *library, const char *name) {
    void *address = dlsym(library, name);
    if (!address) {
        fail("libReqlyCore.so has no %s", name);
    }
    return address;
}

// Only an openFailed event gets printed, since it says why.
static void onEvent(const char *json, void *context) {
    (void)context;
    if (json && strstr(json, "\"openFailed\"")) {
        fprintf(stderr, "smoke: %s\n", json);
    }
}

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t came;
    char *json;
} Reply;

static void onReply(const char *json, void *context) {
    Reply *reply = context;
    pthread_mutex_lock(&reply->lock);
    reply->json = strdup(json ? json : "");
    pthread_cond_signal(&reply->came);
    pthread_mutex_unlock(&reply->lock);
}

// Sends a request and waits up to 30 seconds for its reply, which has to be a result. The caller
// frees it.
static char *call(void *session, const char *request) {
    Reply reply = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, NULL};
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 30;
    waitingFor = request;
    callSession(session, request, onReply, &reply);
    pthread_mutex_lock(&reply.lock);
    while (!reply.json && pthread_cond_timedwait(&reply.came, &reply.lock, &deadline) == 0) {
    }
    char *json = reply.json;
    pthread_mutex_unlock(&reply.lock);
    if (!json) {
        fail("no reply to %s", request);
    }
    if (!strstr(json, "\"result\"")) {
        fail("%s: %s", request, json);
    }
    return json;
}

// Fails unless Swift's runtime was loaded from the folder libReqlyCore.so is in.
static void checkRuntime(const char *library) {
    char real[PATH_MAX];
    if (!realpath(library, real)) {
        fail("can't find %s", library);
    }
    const char *folder = dirname(real);
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) {
        fail("can't read /proc/self/maps");
    }
    char line[PATH_MAX + 128];
    char *runtime = NULL;
    while (!runtime && fgets(line, sizeof line, maps)) {
        char *path = strchr(line, '/');
        if (!path) {
            continue;
        }
        path[strcspn(path, "\n")] = 0;
        size_t length = strlen(path);
        if (length >= 16 && strcmp(path + length - 16, "/libswiftCore.so") == 0) {
            runtime = strdup(path);
        }
    }
    fclose(maps);
    if (!runtime) {
        fail("libswiftCore.so isn't loaded");
    }
    printf("Swift's runtime: %s\n", runtime);
    char copy[PATH_MAX];
    snprintf(copy, sizeof copy, "%s", runtime);
    if (strcmp(dirname(copy), folder) != 0) {
        fail("Swift's runtime came from outside %s", folder);
    }
    free(runtime);
}

// Each read or accept on `descriptor` waits 30 seconds at most.
static void limitWaits(int descriptor) {
    struct timeval timeout = {.tv_sec = 30};
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
}

// Reads until the other end closes, the buffer is full, `end` has come, or nothing more comes.
static void readAll(int connection, char *buffer, size_t size, const char *end) {
    size_t length = 0;
    ssize_t count;
    buffer[0] = 0;
    while (length < size - 1 && (count = read(connection, buffer + length, size - 1 - length)) > 0) {
        length += (size_t)count;
        buffer[length] = 0;
        if (end && strstr(buffer, end)) {
            break;
        }
    }
}

// A server that answers one request, on 127.0.0.1 only. It stops waiting for it after 30
// seconds, as when the proxy never connects.
static int listener;

static void *serve(void *unused) {
    (void)unused;
    int connection = accept(listener, NULL, NULL);
    if (connection < 0) {
        return NULL;
    }
    limitWaits(connection);
    char request[4096];
    readAll(connection, request, sizeof request, "\r\n\r\n");
    const char *response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\n"
                           "Connection: close\r\n\r\nsmoke\n";
    if (write(connection, response, strlen(response)) < 0) {
        perror("smoke: write");
    }
    close(connection);
    return NULL;
}

static int listenLocally(void) {
    listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t size = sizeof address;
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, size) != 0 || listen(listener, 1) != 0
        || getsockname(listener, (struct sockaddr *)&address, &size) != 0) {
        fail("can't listen on 127.0.0.1");
    }
    limitWaits(listener);
    return ntohs(address.sin_port);
}

// Sends a GET through Reqly's proxy and returns the response's first line.
static void requestThrough(int proxy, int server, char *status, size_t size) {
    int connection = socket(AF_INET, SOCK_STREAM, 0);
    limitWaits(connection);
    struct sockaddr_in address = {
        .sin_family = AF_INET, .sin_port = htons((uint16_t)proxy), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (connect(connection, (struct sockaddr *)&address, sizeof address) != 0) {
        fail("can't reach the proxy");
    }
    char request[256];
    snprintf(request, sizeof request,
             "GET http://127.0.0.1:%d/smoke HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n", server,
             server);
    if (write(connection, request, strlen(request)) < 0) {
        fail("can't send through the proxy");
    }
    char response[4096];
    readAll(connection, response, sizeof response, NULL);
    close(connection);
    snprintf(status, size, "%.*s", (int)strcspn(response, "\r\n"), response);
}

static int removeOne(const char *path, const struct stat *info, int type, struct FTW *place) {
    (void)info, (void)type, (void)place;
    return remove(path);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fail("usage: smoke <libReqlyCore.so> [--crash]");
    }
    signal(SIGALRM, onTimeLimit);
    alarm(60);
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fail("%s", dlerror());
    }
    checkRuntime(argv[1]);
    if (argc > 2 && strcmp(argv[2], "--crash") == 0) {
        __typeof__(&reqly_crash_here_for_test) crash = symbol(library, "reqly_crash_here_for_test");
        waitingFor = "the crash's report";
        limitTheCrash();
        crash("Reqly's smoke test crashed on purpose.");
        return 1;
    }
    openSession = symbol(library, "reqly_open");
    callSession = symbol(library, "reqly_call");
    closeSession = symbol(library, "reqly_close");

    // Everything the session keeps goes in a folder of its own, which goes at the end.
    char folder[] = "/tmp/reqly-smoke-XXXXXX";
    if (!mkdtemp(folder)) {
        fail("can't make a folder in /tmp");
    }
    char options[1024];
    snprintf(options, sizeof options,
             "{\"sessionsFolder\":\"%s/Sessions\",\"rootStandIn\":\"%s/Root.dat\",\"findsApps\":false}", folder,
             folder);
    waitingFor = "the session to open";
    void *session = openSession(options, onEvent, NULL);
    if (!session) {
        fail("reqly_open failed");
    }

    free(call(session, "{\"call\":\"version\"}"));
    free(call(session, "{\"call\":\"setUpHTTPS\"}"));
    char *started = call(session, "{\"call\":\"startCapturing\",\"port\":0}");
    char *port = strstr(started, "\"port\":");
    if (!port) {
        fail("no port in %s", started);
    }
    int proxy = atoi(port + 7);
    free(started);

    int server = listenLocally();
    pthread_t serving;
    if (pthread_create(&serving, NULL, serve, NULL) != 0) {
        fail("can't start the server");
    }
    char status[128];
    waitingFor = "the request through Reqly";
    requestThrough(proxy, server, status, sizeof status);
    printf("Through Reqly on port %d: %s\n", proxy, *status ? status : "no response");
    // Without a 200, the request may not have reached the server, which then still waits for it.
    if (strncmp(status, "HTTP/1.1 200", 12) != 0) {
        fail("the request didn't go through");
    }
    pthread_join(serving, NULL);
    close(listener);

    // The exchange reaches the list a moment after its response.
    int listed = 0;
    for (int tries = 0; !listed && tries < 50; tries++) {
        char *summary = call(session, "{\"call\":\"trafficSummary\"}");
        listed = strstr(summary, "\"total\":1") != NULL;
        free(summary);
        if (!listed) {
            usleep(100 * 1000);
        }
    }
    if (!listed) {
        fail("the request isn't in the session");
    }

    free(call(session, "{\"call\":\"stopCapturing\"}"));
    waitingFor = "the session to close";
    closeSession(session);
    if (nftw(folder, removeOne, 16, FTW_DEPTH | FTW_PHYS) != 0) {
        fail("can't remove %s", folder);
    }
    puts("The session opened, captured a request and closed.");
    return 0;
}
