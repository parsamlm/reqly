// For posix_spawn_file_actions_addclosefrom_np, POSIX_SPAWN_SETSID and pipe2.
#define _GNU_SOURCE
#include "CLinux.h"

#if defined(__linux__)
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>

pid_t reqly_trust_spawn(const char *path, char *const argv[], char *const envp[], int input_fd, int output_fd,
                        int error_fd, int new_session) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int error = posix_spawn_file_actions_init(&actions);
    if (error != 0) {
        return -error;
    }
    error = posix_spawnattr_init(&attributes);
    if (error != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return -error;
    }
    // The three descriptors are above standard error, since 0, 1 and 2 are open in Reqly, so
    // copying each into place can't overwrite another. Then everything above standard error closes.
    error = posix_spawn_file_actions_adddup2(&actions, input_fd, 0);
    if (error == 0) {
        error = posix_spawn_file_actions_adddup2(&actions, output_fd, 1);
    }
    if (error == 0) {
        error = posix_spawn_file_actions_adddup2(&actions, error_fd, 2);
    }
    if (error == 0) {
        error = posix_spawn_file_actions_addclosefrom_np(&actions, 3);
    }
    // Signals Reqly ignores, such as SIGPIPE, would stay ignored across exec, and blocked ones
    // blocked.
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    if (error == 0) {
        error = posix_spawnattr_setsigmask(&attributes, &none);
    }
    if (error == 0) {
        error = posix_spawnattr_setsigdefault(&attributes, &all);
    }
    if (error == 0) {
        short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
        error = posix_spawnattr_setflags(&attributes, new_session ? flags | POSIX_SPAWN_SETSID : flags);
    }
    pid_t pid = 0;
    if (error == 0) {
        error = posix_spawn(&pid, path, &actions, &attributes, argv, envp);
    }
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return error != 0 ? -error : pid;
}

int reqly_trust_pipe(int ends[2]) {
    return pipe2(ends, O_CLOEXEC) == 0 ? 0 : -errno;
}
#endif
