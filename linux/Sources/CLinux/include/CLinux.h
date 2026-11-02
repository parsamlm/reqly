// The little of Linux that Swift can't reach cleanly: asking the kernel who owns a TCP socket,
// waiting for a process to end, and starting a process that inherits none of Reqly's
// descriptors. Plain C types only. Each function returns 0 or more when it works, and a negative
// errno when it doesn't, so nothing depends on errno after the call.

#ifndef CLINUX_H
#define CLINUX_H

#include <stdint.h>
#include <sys/types.h>

/// Who owns a TCP socket on this computer, as the kernel's sock_diag reports it.
typedef struct reqly_socket_owner {
    /// The user that created the socket.
    uint32_t uid;
    /// The socket's inode: /proc/<pid>/fd/<n> links to `socket:[inode]` in each process that has
    /// it open.
    uint64_t inode;
    /// The cgroup the socket was created in, which is the inode of its folder under
    /// /sys/fs/cgroup. 0 when the kernel didn't say.
    uint64_t cgroup_id;
} reqly_socket_owner;

/// Finds the connected TCP socket on this computer's loopback whose own port is `local_port` and
/// whose other end's port is `remote_port`, over IPv4, IPv6, or IPv4 through an IPv6 socket, and
/// says who owns it. For the app behind a connection to Reqly, `local_port` is the client's port
/// and `remote_port` Reqly's. Both ends must be on loopback (127.0.0.0/8 or ::1), so a connection
/// to another computer that uses the same two ports doesn't match.
///
/// Needs no privileges. Ask while the connection is open: a closed socket has no owner. Gives up
/// after 200 milliseconds, since the kernel answers at once or not at all.
/// Returns 0 and fills in `owner`, -ENOENT when there's no such socket, or another negative errno:
/// -ETIMEDOUT when the kernel didn't answer.
int reqly_tcp_owner(uint16_t local_port, uint16_t remote_port, reqly_socket_owner *owner);

/// A descriptor for process `pid` that turns readable when it ends, and can't mix it up with a
/// later process given the same ID (Linux 5.3 and later). It's closed on exec. Close it with
/// close(2).
/// Returns the descriptor, or a negative errno: -ESRCH when there's no such process.
int reqly_pidfd_open(pid_t pid);

/// Waits until the process behind `pidfd` ends, for up to `timeout_ms` milliseconds, or with no
/// limit when it's negative. It doesn't reap the process; a parent still calls waitpid.
/// Returns 1 when the process has ended, 0 when the time ran out, or a negative errno.
int reqly_pidfd_wait(int pidfd, int timeout_ms);

/// Starts the program at `path` with `argv` and `envp`, each ending in NULL, in a session of its
/// own, with standard input from /dev/null, standard output and error to `output_fd`, or to
/// /dev/null when it's negative, every other descriptor closed and every signal at its default.
/// So it keeps none of Reqly's sockets or files open, and outlives Reqly's terminal.
///
/// It doesn't wait. The new process is still Reqly's child, so Reqly reaps it with waitpid once
/// it ends, such as when its pidfd turns readable. Needs glibc 2.34 or later.
/// Returns the new process's ID, or a negative errno: -ENOENT when there's no such program.
pid_t reqly_spawn_detached(const char *path, char *const argv[], char *const envp[], int output_fd);

/// Starts the program at `path` with `argv` and `envp`, each ending in NULL, as a tool Reqly
/// waits for, such as certutil or pkexec: standard input, output and error from the descriptors
/// given, every other descriptor closed and every signal at its default. With `new_session`, it
/// starts a session of its own, without the terminal Reqly may have been started from, so pkexec
/// never asks for a password there. Reqly reaps it with waitpid. In trust.c.
/// Returns the new process's ID, or a negative errno: -ENOENT when there's no such program.
pid_t reqly_trust_spawn(const char *path, char *const argv[], char *const envp[], int input_fd, int output_fd,
                        int error_fd, int new_session);

/// A pipe whose two ends close on exec, so no other process Reqly starts meanwhile inherits them.
/// Fills in `ends`, the end to read first. In trust.c.
/// Returns 0, or a negative errno.
int reqly_trust_pipe(int ends[2]);

#endif
