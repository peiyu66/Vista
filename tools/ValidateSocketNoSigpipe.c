/* Local macOS regression harness. No NAS, SMB requests, or network connect.
 * Compiles the actual dependency socket.c; only socket syscall boundaries and
 * error reporting are replaced for connect_async_ai. Unused SMB code is stripped.
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(__APPLE__) || !defined(SO_NOSIGPIPE)
#error This mechanism test requires macOS SO_NOSIGPIPE.
#endif

struct smb2_context;
static int test_socket(int, int, int);
static int test_setsockopt(int, int, int, const void *, socklen_t);
static int test_connect(int, const struct sockaddr *, socklen_t);
static int test_close(int);
static int test_fcntl(int, int, ...);
static struct protoent *test_getprotobyname(const char *);

/* System headers are already loaded, so macros replace calls in production
 * source only. No linker interposition or changes to the app are involved. */
#define socket test_socket
#define setsockopt test_setsockopt
#define connect test_connect
#define close test_close
#define fcntl test_fcntl
#define getprotobyname test_getprotobyname
#define smb2_set_error test_smb2_set_error
#include "../Dependencies/AMSMB2/Dependencies/libsmb2/lib/socket.c"
#undef socket
#undef setsockopt
#undef connect
#undef close
#undef fcntl
#undef getprotobyname
#undef smb2_set_error

static struct {
    int family, fd, socket_errno, option_errno, connect_errno;
    int socket_calls, guard_calls, tcp_calls, connect_calls, close_calls;
    int fcntl_calls, error_calls, violation, error_clobber, close_clobber;
    char events[128], error[512];
    size_t event_count;
} stub;

static void event(char value)
{
    if (stub.event_count + 1 < sizeof(stub.events)) {
        stub.events[stub.event_count++] = value;
        stub.events[stub.event_count] = '\0';
    } else {
        stub.violation = 1;
    }
}

static int test_socket(int family, int type, int protocol)
{
    event('S');
    stub.socket_calls++;
    if (family != stub.family || type != SOCK_STREAM || protocol != 0)
        stub.violation = 1;
    if (stub.socket_errno) {
        errno = stub.socket_errno;
        return -1;
    }
    return stub.fd;
}

static int test_setsockopt(int fd, int level, int option,
                           const void *value, socklen_t size)
{
    if (fd != stub.fd || size != sizeof(int) || *(const int *)value != 1)
        stub.violation = 1;
    if (level == SOL_SOCKET && option == SO_NOSIGPIPE) {
        event('G');
        stub.guard_calls++;
        if (stub.socket_calls != 1 || stub.connect_calls || stub.fcntl_calls ||
            stub.guard_calls != 1)
            stub.violation = 1;
        if (stub.option_errno) {
            errno = stub.option_errno;
            return -1;
        }
        return 0;
    }
    if (level == IPPROTO_TCP && option == TCP_NODELAY) {
        event('T');
        stub.tcp_calls++;
        if (stub.guard_calls != 1 || stub.option_errno)
            stub.violation = 1;
        return 0;
    }
    stub.violation = 1;
    errno = ENOPROTOOPT;
    return -1;
}

static int test_fcntl(int fd, int command, ...)
{
    event('F');
    stub.fcntl_calls++;
    if (fd != stub.fd || stub.guard_calls != 1 || stub.option_errno)
        stub.violation = 1;
    if (command == F_GETFL)
        return 0;
    if (command == F_SETFL) {
        va_list args;
        va_start(args, command);
        int flags = va_arg(args, int);
        va_end(args);
        if (!(flags & O_NONBLOCK))
            stub.violation = 1;
        return 0;
    }
    stub.violation = 1;
    return -1;
}

static struct protoent *test_getprotobyname(const char *name)
{
    static struct protoent tcp = { .p_name = "tcp", .p_proto = IPPROTO_TCP };
    if (strcmp(name, "tcp"))
        stub.violation = 1;
    return &tcp;
}

static int test_connect(int fd, const struct sockaddr *address, socklen_t size)
{
    event('C');
    stub.connect_calls++;
    if (fd != stub.fd || stub.guard_calls != 1 || stub.option_errno ||
        stub.fcntl_calls != 2 || stub.tcp_calls != 1 ||
        address->sa_family != stub.family ||
        size != (stub.family == AF_INET ? sizeof(struct sockaddr_in) :
                                          sizeof(struct sockaddr_in6)))
        stub.violation = 1;
    /* Intentionally never calls the system connect(). */
    if (stub.connect_errno) {
        errno = stub.connect_errno;
        return -1;
    }
    return 0;
}

static int test_close(int fd)
{
    event('X');
    stub.close_calls++;
    if (fd != stub.fd)
        stub.violation = 1;
    errno = stub.close_clobber;
    return stub.close_clobber ? -1 : 0;
}

void test_smb2_set_error(struct smb2_context *context, const char *format, ...)
{
    (void)context;
    event('E');
    stub.error_calls++;
    va_list args;
    va_start(args, format);
    vsnprintf(stub.error, sizeof(stub.error), format, args);
    va_end(args);
    errno = stub.error_clobber;
}

static int total, failures;
static void result(const char *suite, const char *name, int okay, const char *detail)
{
    ++total;
    if (!okay)
        ++failures;
    printf("%s %d - %s/%s [%s]\n", okay ? "ok" : "not ok", total,
           suite, name, detail);
    fflush(stdout);
}

enum scenario { IMMEDIATE, IN_PROGRESS, GUARD_EPERM, GUARD_ENOPROTOOPT,
                SOCKET_EMFILE, CONNECT_REFUSED };

static void production_case(int family, enum scenario scenario, int fd)
{
    static const char *names[] = { "immediate", "einprogress", "guard-eperm",
        "guard-enoprotoopt", "socket-emfile", "connect-refused" };
    struct smb2_context context;
    struct sockaddr_storage address;
    struct addrinfo ai;
    int fd_out = -777;
    memset(&stub, 0, sizeof(stub));
    memset(&context, 0, sizeof(context));
    memset(&address, 0, sizeof(address));
    memset(&ai, 0, sizeof(ai));
    stub.family = family;
    stub.fd = fd;
    stub.error_clobber = EDOM;
    stub.close_clobber = EBADF;
    stub.option_errno = scenario == GUARD_EPERM ? EPERM :
                        scenario == GUARD_ENOPROTOOPT ? ENOPROTOOPT : 0;
    stub.socket_errno = scenario == SOCKET_EMFILE ? EMFILE : 0;
    stub.connect_errno = scenario == IN_PROGRESS ? EINPROGRESS :
                         scenario == CONNECT_REFUSED ? ECONNREFUSED : 0;
    address.ss_family = family;
    ai.ai_family = family;
    ai.ai_addr = (struct sockaddr *)&address;
    ai.ai_addrlen = family == AF_INET ? sizeof(struct sockaddr_in) :
                                      sizeof(struct sockaddr_in6);
    errno = 0;
    int status = connect_async_ai(&context, &ai, &fd_out);
    int okay = !stub.violation && stub.socket_calls == 1;
    if (stub.option_errno) {
        char number[32];
        snprintf(number, sizeof(number), "(%d)", stub.option_errno);
        okay &= status == -stub.option_errno && fd_out == -777 &&
            stub.guard_calls == 1 && stub.close_calls == 1 &&
            stub.connect_calls == 0 && stub.fcntl_calls == 0 &&
            stub.tcp_calls == 0 && stub.error_calls == 1 &&
            strcmp(stub.events, "SGEX") == 0 &&
            strstr(stub.error, "SO_NOSIGPIPE") != NULL &&
            strstr(stub.error, strerror(stub.option_errno)) != NULL &&
            strstr(stub.error, number) != NULL && errno == EBADF;
    } else if (stub.socket_errno) {
        okay &= status == -EIO && fd_out == -777 &&
            stub.guard_calls == 0 && stub.close_calls == 0 &&
            stub.connect_calls == 0 && stub.fcntl_calls == 0 &&
            stub.error_calls == 1 && strcmp(stub.events, "SE") == 0 &&
            strstr(stub.error, "Failed to open smb2 socket") != NULL;
    } else if (scenario == CONNECT_REFUSED) {
        okay &= status == -EIO && fd_out == -777 &&
            stub.close_calls == 1 && stub.error_calls == 1 &&
            strcmp(stub.events, "SGFFTCEX") == 0 &&
            strstr(stub.error, "Connect failed") != NULL;
    } else {
        okay &= status == 0 && fd_out == fd && stub.close_calls == 0 &&
            stub.error_calls == 0 && strcmp(stub.events, "SGFFTC") == 0;
    }
    char name[128], detail[256];
    snprintf(name, sizeof(name), "%s-%s-fd%d", family == AF_INET ? "ipv4" : "ipv6",
             names[scenario], fd);
    snprintf(detail, sizeof(detail), "return=%d fd_out=%d events=%s errno=%d",
             status, fd_out, stub.events, errno);
    result("production", name, okay, detail);
}

static void production_tests(void)
{
    for (int family_index = 0; family_index < 2; ++family_index)
        for (int scenario = IMMEDIATE; scenario <= CONNECT_REFUSED; ++scenario)
            production_case(family_index ? AF_INET6 : AF_INET, scenario,
                            100 + 10 * family_index + scenario);
    /* A second new socket in each family must receive its own option. */
    production_case(AF_INET, IMMEDIATE, 201);
    production_case(AF_INET6, IMMEDIATE, 202);
    struct smb2_context context;
    struct addrinfo ai;
    memset(&stub, 0, sizeof(stub));
    memset(&context, 0, sizeof(context));
    memset(&ai, 0, sizeof(ai));
    ai.ai_family = AF_UNIX;
    int fd = -777;
    int status = connect_async_ai(&context, &ai, &fd);
    result("production", "unsupported-family", status == -EINVAL && fd == -777 &&
           stub.socket_calls == 0 && stub.connect_calls == 0 &&
           stub.error_calls == 1 && strcmp(stub.events, "E") == 0,
           "unsupported family rejected without creating socket");
}

/* Real syscalls below use only AF_UNIX socketpair, inside sequential children.
 * SIGPIPE is reset/unblocked only in each isolated child, never in the parent. */
static void child_require(int condition, int code)
{
    if (!condition)
        _exit(code);
}

static int option_value(int fd)
{
    int value = -1;
    socklen_t size = sizeof(value);
    child_require(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &size) == 0, 80);
    child_require(size == sizeof(value), 81);
    return value;
}

static void enable_guard(int fd)
{
    const int value = 1;
    child_require(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, sizeof(value)) == 0, 82);
    child_require(option_value(fd) == 1, 83);
}

static ssize_t one_writev(int fd)
{
    struct iovec pieces[] = { { .iov_base = "local-", .iov_len = 6 },
                             { .iov_base = "only", .iov_len = 4 } };
    return writev(fd, pieces, 2);
}

static void child_case(int which)
{
    struct sigaction action = {0}, after = {0};
    sigset_t pipe_mask, after_mask;
    struct rlimit core = {0, 0};
    child_require(setrlimit(RLIMIT_CORE, &core) == 0, 70);
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    child_require(sigaction(SIGPIPE, &action, NULL) == 0, 71);
    sigemptyset(&pipe_mask);
    sigaddset(&pipe_mask, SIGPIPE);
    child_require(sigprocmask(SIG_UNBLOCK, &pipe_mask, NULL) == 0, 72);
    alarm(5);
    int pair[2];
    child_require(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, 73);
    child_require(option_value(pair[0]) == 0 && option_value(pair[1]) == 0, 74);
    int protected = which == 1 || which == 3 || which == 4 || which == 5;
    if (protected)
        enable_guard(pair[0]);
    child_require(sigaction(SIGPIPE, NULL, &after) == 0 &&
                  after.sa_handler == SIG_DFL, 75);
    child_require(sigprocmask(SIG_SETMASK, NULL, &after_mask) == 0 &&
                  sigismember(&after_mask, SIGPIPE) == 0, 76);
    child_require(option_value(pair[1]) == 0, 77);
    if (which == 2 || which == 3) {
        child_require(one_writev(pair[0]) == 10, 84);
        char bytes[16] = {0};
        child_require(read(pair[1], bytes, sizeof(bytes)) == 10 &&
                      memcmp(bytes, "local-only", 10) == 0, 85);
        close(pair[0]);
        close(pair[1]);
        _exit(0);
    }
    if (which == 4) {
        /* The peer never inherited the option; closing guarded endpoint must
         * still leave the unguarded peer subject to default SIGPIPE. */
        close(pair[0]);
        (void)one_writev(pair[1]);
        _exit(86);
    }
    child_require(close(pair[1]) == 0, 87);
    errno = 0;
    ssize_t count = one_writev(pair[0]);
    if (!protected)
        _exit(88); /* Reaching here means expected SIGPIPE did not happen. */
    child_require(count == -1 && errno == EPIPE, 89);
    child_require(sigaction(SIGPIPE, NULL, &after) == 0 &&
                  after.sa_handler == SIG_DFL, 90);
    close(pair[0]);
    if (which == 5) {
        /* A later new socket is also unprotected: no process-wide ignore. */
        child_require(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, 91);
        child_require(option_value(pair[0]) == 0, 92);
        close(pair[1]);
        (void)one_writev(pair[0]);
        _exit(93);
    }
    _exit(0);
}

static void mechanism_tests(void)
{
    static const char *names[] = { "unprotected-broken-sigpipe", "protected-broken-epipe",
        "unprotected-normal-write", "protected-normal-write",
        "peer-socket-remains-unprotected", "next-socket-remains-unprotected" };
    struct sigaction before = {0}, after = {0};
    sigset_t before_mask = 0, after_mask = 0;
    int capture = sigaction(SIGPIPE, NULL, &before) == 0 &&
                  sigprocmask(SIG_SETMASK, NULL, &before_mask) == 0;
    for (int which = 0; which < 6; ++which) {
        fflush(NULL);
        pid_t child = fork();
        if (child == 0)
            child_case(which);
        int status = 0;
        pid_t waited = -1;
        if (child > 0) {
            do { waited = waitpid(child, &status, 0); }
            while (waited < 0 && errno == EINTR);
        }
        int expect_signal = which == 0 || which == 4 || which == 5;
        int okay = child > 0 && waited == child && (expect_signal ?
            WIFSIGNALED(status) && WTERMSIG(status) == SIGPIPE :
            WIFEXITED(status) && WEXITSTATUS(status) == 0);
        char detail[128];
        snprintf(detail, sizeof(detail), "exited=%d exit=%d signaled=%d signal=%d",
            WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1,
            WIFSIGNALED(status), WIFSIGNALED(status) ? WTERMSIG(status) : -1);
        result("mechanism", names[which], okay, detail);
    }
    int unchanged = capture && sigaction(SIGPIPE, NULL, &after) == 0 &&
                    sigprocmask(SIG_SETMASK, NULL, &after_mask) == 0 &&
                    before.sa_handler == after.sa_handler &&
                    before.sa_flags == after.sa_flags;
    for (int signal_number = 1; signal_number < NSIG; ++signal_number)
        unchanged &= sigismember(&before_mask, signal_number) ==
                     sigismember(&after_mask, signal_number) &&
                     sigismember(&before.sa_mask, signal_number) ==
                     sigismember(&after.sa_mask, signal_number);
    result("mechanism", "parent-signal-state-unchanged", unchanged,
           "SIGPIPE disposition/handler mask and parent signal mask unchanged");
}

int main(void)
{
    puts("TAP version 13");
    production_tests();
    mechanism_tests();
    printf("1..%d\n# tests=%d passed=%d failed=%d\n", total, total,
           total - failures, failures);
    puts("# Scope: macOS local mechanism and production function with syscall stubs only.");
    puts("# No NAS/network connect/SMB request, Vision Pro validation, or repair claim.");
    return failures ? 1 : 0;
}
