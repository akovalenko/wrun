/* forwarder — winelib bridge from the Wine world to build-host tools.
 *
 * Build (bare winegcc, no wine headers needed — POSIX source plus a
 * hand-declared sliver of win32, resolved from winegcc's import libs):
 *     winegcc -o a.out forwarder.c        # produces a.out + a.out.so
 *
 * Install: symlink <tool>.exe -> a.out.so (see gen-shims.sh) in a
 * directory listed in WINEPATH.  When a Windows process (e.g. SBCL's
 * run-program) does CreateProcess("<tool>.exe", ...), Wine loads this
 * winelib program instead.  It:
 *   1. strips the directory and ".exe" suffix from argv[0],
 *   2. rewrites Windows-absolute-path arguments ("Z:\home\...") into
 *      Unix form by resolving $WINEPREFIX/dosdevices/<drive>:,
 *   3. posix_spawnp()s the real <tool> from the Unix PATH, bridging
 *      stdio and returning its exit status.
 *
 * Stdio needs the bridging (not plain fd inheritance): when the Wine
 * parent redirects std handles to Windows pipes (SBCL's run-program
 * with lisp streams), those pipes live in wineserver and have no Unix
 * fd in this process — Wine points our Unix fds 0/1 at /dev/null and
 * leaves 2 wherever the Unix-side wine process inherited it.  So the
 * child runs on our own Unix pipes, and per-stream pump threads copy
 * bytes between those pipes and the Windows std handles.
 *
 * Descendant of Anton Kovalenko's runp/wrapper.c; the path
 * translation used to live in per-tool shell shims on the Unix side.
 * Deliberately no wine headers (absent in runtime-only wine
 * packages): dosdevices symlinks replace wine_get_unix_file_name, and
 * the few kernel32 calls below are declared by hand — their import
 * stubs ship with every winegcc.
 */
#define _GNU_SOURCE     /* pipe2 */
#include <stdio.h>
#include <fcntl.h>
#include <spawn.h>
#include <errno.h>
#include <ctype.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* Minimal win32 surface (win64 ABI). */
#define WINAPI __attribute__((ms_abi))
typedef void *HANDLE;
typedef unsigned int DWORD;
typedef int WBOOL;
WINAPI HANDLE GetStdHandle(DWORD);
WINAPI WBOOL ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
WINAPI WBOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
WINAPI HANDLE CreateThread(void *, unsigned long, DWORD (WINAPI *)(void *),
                           void *, DWORD, DWORD *);
WINAPI DWORD WaitForSingleObject(HANDLE, DWORD);
#define STD_INPUT_HANDLE  ((DWORD)-10)
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define STD_ERROR_HANDLE  ((DWORD)-12)
#define INFINITE          ((DWORD)-1)

struct pump {
    HANDLE win;
    int fd;
    int to_child;   /* 1: win handle -> fd (child stdin), 0: fd -> win */
};

static DWORD WINAPI pump_thread(void *arg)
{
    struct pump *p = arg;
    /* plain stack buffer: a __thread one gets ERROR_INVALID_USER_BUFFER
     * (1784) out of wine's ReadFile */
    char buf[65536];

    if (p->to_child) {
        DWORD n;
        while (ReadFile(p->win, buf, sizeof buf, &n, NULL) && n) {
            DWORD off = 0;
            while (off < n) {
                ssize_t w = write(p->fd, buf + off, n - off);
                if (w < 0) {
                    if (errno == EINTR)
                        continue;
                    goto out;
                }
                off += w;
            }
        }
    } else {
        ssize_t n;
        for (;;) {
            n = read(p->fd, buf, sizeof buf);
            if (n == 0)
                break;
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                break;
            }
            ssize_t off = 0;
            while (off < n) {
                DWORD w;
                if (WriteFile(p->win, buf + off, (DWORD)(n - off), &w, NULL) == 0)
                    goto out;
                off += w;
            }
        }
    }
out:
    close(p->fd);
    return 0;
}

/* Wire one std stream: pipe to the child + a pump thread spec.
 * Returns the parent-side close-after-spawn fd, -1 if left alone. */
static int wire_stream(posix_spawn_file_actions_t *fa, struct pump *pump,
                       DWORD nstd, int childfd)
{
    HANDLE h = GetStdHandle(nstd);
    int p[2];

    if (h == NULL || h == (HANDLE)(long)-1)
        return -1;
    if (pipe2(p, O_CLOEXEC))
        return -1;
    /* child stdin reads our pipe; stdout/stderr write it */
    posix_spawn_file_actions_adddup2(fa, childfd == 0 ? p[0] : p[1], childfd);
    pump->win = h;
    pump->fd = childfd == 0 ? p[1] : p[0];
    pump->to_child = childfd == 0;
    return childfd == 0 ? p[0] : p[1];
}

static const char *wineprefix(void)
{
    static char buf[PATH_MAX];
    const char *p = getenv("WINEPREFIX");
    const char *home;

    if (p && *p)
        return p;
    home = getenv("HOME");
    if (!home)
        return NULL;
    snprintf(buf, sizeof buf, "%s/.wine", home);
    return buf;
}

/* "Z:\foo" / "c:/bar" -> Unix path per dosdevices; else unchanged. */
static char *maybe_translate(char *arg)
{
    const char *prefix;
    char link[PATH_MAX], target[PATH_MAX];
    char *out, *p;
    ssize_t n;
    size_t outlen;

    if (!(isalpha((unsigned char)arg[0]) && arg[1] == ':'
          && (arg[2] == '\\' || arg[2] == '/')))
        return arg;
    prefix = wineprefix();
    if (!prefix)
        return arg;
    snprintf(link, sizeof link, "%s/dosdevices/%c:",
             prefix, tolower((unsigned char)arg[0]));
    n = readlink(link, target, sizeof target - 1);
    if (n < 0)
        return arg;
    target[n] = '\0';
    while (n > 1 && target[n-1] == '/')
        target[--n] = '\0';

    outlen = strlen(prefix) + sizeof "/dosdevices/" + n + strlen(arg + 2) + 1;
    out = malloc(outlen);
    if (!out)
        return arg;
    if (target[0] == '/')
        snprintf(out, outlen, "%s%s",
                 strcmp(target, "/") ? target : "", arg + 2);
    else /* relative link, e.g. c: -> ../drive_c */
        snprintf(out, outlen, "%s/dosdevices/%s%s", prefix, target, arg + 2);
    for (p = out; *p; p++)
        if (*p == '\\')
            *p = '/';
    return out;
}

int main(int argc, char *argv[], char *envp[])
{
    char *me = argv[0];
    size_t len = strlen(me);
    int i, dot = (int)len, slash = -1;
    pid_t child;
    int rc, wstatus, status = 255;
    posix_spawn_file_actions_t fa;
    struct pump pumps[3];
    int child_ends[3];
    HANDLE drain[2];
    int ndrain = 0;

    if (len > 65535)
        return 255;

    /* argv[0] is ".../<tool>.exe"; reduce it to "<tool>". */
    for (i = (int)len - 1; i > 0; i--) {
        if (me[i] == '/' || me[i] == '\\') {
            slash = i;
            break;
        }
        if (me[i] == '.')
            dot = i;
    }
    me[dot] = '\0';
    argv[0] = me + slash + 1;

    for (i = 1; i < argc; i++)
        argv[i] = maybe_translate(argv[i]);

    posix_spawn_file_actions_init(&fa);
    child_ends[0] = wire_stream(&fa, &pumps[0], STD_INPUT_HANDLE, 0);
    child_ends[1] = wire_stream(&fa, &pumps[1], STD_OUTPUT_HANDLE, 1);
    child_ends[2] = wire_stream(&fa, &pumps[2], STD_ERROR_HANDLE, 2);

    rc = posix_spawnp(&child, argv[0], &fa, NULL, argv, envp);
    if (rc) {
        errno = rc;
        perror("forwarder: posix_spawnp");
        return 255;
    }
    for (i = 0; i < 3; i++) {
        HANDLE t;
        if (child_ends[i] < 0)
            continue;
        close(child_ends[i]);
        t = CreateThread(NULL, 0, pump_thread, &pumps[i], 0, NULL);
        if (t == NULL)
            close(pumps[i].fd);        /* child sees EOF/EPIPE */
        else if (i > 0)
            drain[ndrain++] = t;       /* stdin pump is not waited for */
    }

    for (;;) {
        pid_t wr = waitpid(child, &wstatus, 0);
        if (wr == -1) {
            if (errno != EINTR)
                break;
            continue;
        }
        if (WIFEXITED(wstatus)) {
            status = WEXITSTATUS(wstatus);
            break;
        }
        if (WIFSIGNALED(wstatus)) {
            status = 128 + WTERMSIG(wstatus);
            break;
        }
    }
    /* let output reach the Windows pipes before the process goes away */
    for (i = 0; i < ndrain; i++)
        WaitForSingleObject(drain[i], INFINITE);
    return status;
}
