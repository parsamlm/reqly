// For posix_spawn_file_actions_addclosefrom_np and POSIX_SPAWN_SETSID.
#define _GNU_SOURCE
#include "CLinux.h"

#if defined(__linux__)
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/inet_diag.h>
#include <linux/netlink.h>
#include <linux/sock_diag.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

// Linux 5.7's headers name it, and older ones don't.
#ifndef INET_DIAG_CGROUP_ID
#define INET_DIAG_CGROUP_ID 21
#endif
// The same number on every architecture.
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

// The states in which a socket still has its owner, as bits of inet_diag's state mask. Closed and
// time-wait sockets come back with user 0, inode 0 and no cgroup.
#define OWNED_STATES                                                                                         \
    ((1u << TCP_ESTABLISHED) | (1u << TCP_FIN_WAIT1) | (1u << TCP_FIN_WAIT2) | (1u << TCP_CLOSE_WAIT) |      \
     (1u << TCP_LAST_ACK) | (1u << TCP_CLOSING))

// Whether a socket's address, as inet_diag gives it, is on this computer's loopback: 127.0.0.0/8,
// ::1, or 127.0.0.0/8 through an IPv6 socket (::ffff:127.x.x.x).
static int is_loopback(uint8_t family, const uint32_t address[4]) {
    const uint8_t *bytes = (const uint8_t *)address;
    if (family == AF_INET) {
        return bytes[0] == 127;
    }
    static const uint8_t one[16] = {[15] = 1};
    static const uint8_t mapped[12] = {[10] = 0xff, [11] = 0xff};
    return memcmp(bytes, one, 16) == 0 || (memcmp(bytes, mapped, 12) == 0 && bytes[12] == 127);
}

// Reads one socket's owner from the kernel's reply about it.
static void read_owner(const struct nlmsghdr *reply, const struct inet_diag_msg *found, reqly_socket_owner *owner) {
    owner->uid = found->idiag_uid;
    owner->inode = found->idiag_inode;
    owner->cgroup_id = 0;
    // The attributes follow the message. The cgroup's ID is one of them since Linux 5.8, sent
    // without asking, as ss shows it.
    const char *attribute = (const char *)found + NLMSG_ALIGN(sizeof(struct inet_diag_msg));
    int left = (int)reply->nlmsg_len - (int)NLMSG_LENGTH(sizeof(struct inet_diag_msg));
    while (left >= (int)NLA_HDRLEN) {
        const struct nlattr *header = (const struct nlattr *)attribute;
        if (header->nla_len < NLA_HDRLEN || header->nla_len > left) {
            break;
        }
        if ((header->nla_type & NLA_TYPE_MASK) == INET_DIAG_CGROUP_ID &&
            header->nla_len >= NLA_HDRLEN + sizeof(uint64_t)) {
            memcpy(&owner->cgroup_id, attribute + NLA_HDRLEN, sizeof(uint64_t));
        }
        left -= NLA_ALIGN(header->nla_len);
        attribute += NLA_ALIGN(header->nla_len);
    }
}

// How to ask the kernel for a socket.
enum question {
    // For the one socket from 127.0.0.1 to 127.0.0.1 with these ports: one look in the kernel's
    // hash table. It finds IPv4 through IPv6 sockets too.
    EXACT_IPV4,
    // For the one socket from ::1 to ::1.
    EXACT_IPV6,
    // For every socket of a family whose ports match, as ss does, which goes through the kernel's
    // whole table, about a millisecond. It finds the rest of loopback, such as 127.0.1.1.
    MATCHING_IPV4,
    MATCHING_IPV6,
};

// Asks the kernel one question on a new netlink socket, and fills in the owner of the connected
// socket it finds whose both ends are on loopback. A port pair alone could also match a connection
// to another computer that happens to use the same two ports. Returns 0, -ENOENT when none
// matched, or another negative errno.
static int ask(enum question question, uint16_t local_port, uint16_t remote_port, reqly_socket_owner *owner) {
    struct {
        struct nlmsghdr header;
        struct inet_diag_req_v2 request;
        struct nlattr filter_header;
        struct inet_diag_bc_op filter[4];
    } message;
    memset(&message, 0, sizeof(message));
    int is_exact = question == EXACT_IPV4 || question == EXACT_IPV6;
    uint8_t family = (question == EXACT_IPV4 || question == MATCHING_IPV4) ? AF_INET : AF_INET6;
    message.header.nlmsg_type = SOCK_DIAG_BY_FAMILY;
    message.request.sdiag_family = family;
    message.request.sdiag_protocol = IPPROTO_TCP;
    if (is_exact) {
        message.header.nlmsg_len = NLMSG_LENGTH(sizeof(struct inet_diag_req_v2));
        message.header.nlmsg_flags = NLM_F_REQUEST;
        message.request.id.idiag_sport = htons(local_port);
        message.request.id.idiag_dport = htons(remote_port);
        if (family == AF_INET) {
            message.request.id.idiag_src[0] = htonl(INADDR_LOOPBACK);
            message.request.id.idiag_dst[0] = htonl(INADDR_LOOPBACK);
        } else {
            message.request.id.idiag_src[3] = htonl(1);
            message.request.id.idiag_dst[3] = htonl(1);
        }
        message.request.id.idiag_cookie[0] = INET_DIAG_NOCOOKIE;
        message.request.id.idiag_cookie[1] = INET_DIAG_NOCOOKIE;
    } else {
        message.header.nlmsg_len = sizeof(message);
        message.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
        message.request.idiag_states = OWNED_STATES;
        // The kernel runs this filter on each socket, so only the matches come back. Each test is
        // two ops, the second holding the port. A test that passes goes on to the next op (8 bytes
        // on); one that fails jumps 4 bytes past the end, which rejects the socket.
        message.filter_header.nla_len = sizeof(message.filter_header) + sizeof(message.filter);
        message.filter_header.nla_type = INET_DIAG_REQ_BYTECODE;
        message.filter[0] = (struct inet_diag_bc_op){INET_DIAG_BC_S_EQ, 8, 20};
        message.filter[1] = (struct inet_diag_bc_op){0, 0, local_port};
        message.filter[2] = (struct inet_diag_bc_op){INET_DIAG_BC_D_EQ, 8, 12};
        message.filter[3] = (struct inet_diag_bc_op){0, 0, remote_port};
    }

    // A new netlink socket for each question, so nothing left of one answer mixes into the next.
    int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_SOCK_DIAG);
    if (fd < 0) {
        return -errno;
    }
    struct timeval limit = {.tv_usec = 200 * 1000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
    struct sockaddr_nl kernel = {.nl_family = AF_NETLINK};
    if (sendto(fd, &message, message.header.nlmsg_len, 0, (struct sockaddr *)&kernel, sizeof(kernel)) < 0) {
        int error = errno;
        close(fd);
        return -error;
    }
    // More than the 32 KB the kernel puts in one reply, so none is cut short.
    size_t size = 64 * 1024;
    char *buffer = malloc(size);
    if (buffer == NULL) {
        close(fd);
        return -ENOMEM;
    }
    int result = -ENOENT;
    for (;;) {
        ssize_t length = recv(fd, buffer, size, 0);
        if (length < 0) {
            if (errno == EINTR) {
                continue;
            }
            result = (errno == EAGAIN || errno == EWOULDBLOCK) ? -ETIMEDOUT : -errno;
            break;
        }
        if (length == 0) {
            break;
        }
        for (struct nlmsghdr *reply = (struct nlmsghdr *)buffer; NLMSG_OK(reply, length);
             reply = NLMSG_NEXT(reply, length)) {
            if (reply->nlmsg_type == NLMSG_DONE) {
                goto done;
            }
            if (reply->nlmsg_type == NLMSG_ERROR) {
                // An exact question for a socket that isn't there gets -ENOENT.
                struct nlmsgerr *error = NLMSG_DATA(reply);
                result = error->error < 0 ? error->error : -EIO;
                goto done;
            }
            if (reply->nlmsg_type != SOCK_DIAG_BY_FAMILY ||
                reply->nlmsg_len < NLMSG_LENGTH(sizeof(struct inet_diag_msg))) {
                continue;
            }
            struct inet_diag_msg *found = NLMSG_DATA(reply);
            // An exact question finds closing sockets too, which have no owner.
            int is_owned = (OWNED_STATES & (1u << found->idiag_state)) != 0;
            if (!is_owned || !is_loopback(found->idiag_family, found->id.idiag_src) ||
                !is_loopback(found->idiag_family, found->id.idiag_dst)) {
                if (is_exact) {
                    goto done;
                }
                continue;
            }
            read_owner(reply, found, owner);
            // The rest of a dump is left unread: its netlink socket is closed.
            result = 0;
            goto done;
        }
        if (is_exact) {
            // The answer to an exact question is one message.
            break;
        }
    }
done:
    free(buffer);
    close(fd);
    return result;
}

int reqly_tcp_owner(uint16_t local_port, uint16_t remote_port, reqly_socket_owner *owner) {
    // The likeliest first: almost every app reaches Reqly at 127.0.0.1 or ::1.
    enum question questions[] = {EXACT_IPV4, EXACT_IPV6, MATCHING_IPV4, MATCHING_IPV6};
    int result = -ENOENT;
    for (size_t index = 0; index < sizeof(questions) / sizeof(questions[0]) && result == -ENOENT; index++) {
        result = ask(questions[index], local_port, remote_port, owner);
    }
    return result;
}

int reqly_pidfd_open(pid_t pid) {
    // It's always closed on exec.
    long fd = syscall(SYS_pidfd_open, pid, 0);
    return fd < 0 ? -errno : (int)fd;
}

static int64_t now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

int reqly_pidfd_wait(int pidfd, int timeout_ms) {
    int64_t deadline = now_ms() + (timeout_ms < 0 ? 0 : timeout_ms);
    for (;;) {
        // The clock is read once, so the time left can't come out negative, which would wait
        // with no limit.
        int64_t left = deadline - now_ms();
        int wait = timeout_ms < 0 ? -1 : (int)(left > 0 ? left : 0);
        struct pollfd poll_fd = {.fd = pidfd, .events = POLLIN};
        int ready = poll(&poll_fd, 1, wait);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -errno;
        }
        if (ready == 0) {
            return 0;
        }
        if (poll_fd.revents & POLLNVAL) {
            return -EBADF;
        }
        return 1;
    }
}

pid_t reqly_spawn_detached(const char *path, char *const argv[], char *const envp[], int output_fd) {
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
    // In order, in the child: output first, so an output_fd of 0 still works, then input, then
    // everything above standard error closed.
    if (output_fd >= 0) {
        error = posix_spawn_file_actions_adddup2(&actions, output_fd, 1);
    } else {
        error = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    }
    if (error == 0) {
        error = posix_spawn_file_actions_adddup2(&actions, 1, 2);
    }
    if (error == 0) {
        error = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
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
        error = posix_spawnattr_setflags(
            &attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    }
    pid_t pid = 0;
    if (error == 0) {
        error = posix_spawn(&pid, path, &actions, &attributes, argv, envp);
    }
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return error != 0 ? -error : pid;
}
#endif
