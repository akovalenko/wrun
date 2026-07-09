/* forwarder — winelib bridge from the Wine world to build-host tools.
 *
 * Build (bare winegcc, no wine headers needed — pure POSIX source):
 *     winegcc -o a.out forwarder.c        # produces a.out + a.out.so
 *
 * Install: symlink <tool>.exe -> a.out.so (see gen-shims.sh) in a
 * directory listed in WINEPATH.  When a Windows process (e.g. SBCL's
 * run-program) does CreateProcess("<tool>.exe", ...), Wine loads this
 * winelib program instead.  It:
 *   1. strips the directory and ".exe" suffix from argv[0],
 *   2. rewrites Windows-absolute-path arguments ("Z:\home\...") into
 *      Unix form by resolving $WINEPREFIX/dosdevices/<drive>:,
 *   3. posix_spawnp()s the real <tool> from the Unix PATH, forwarding
 *      stdio and returning its exit status.
 *
 * Descendant of Anton Kovalenko's runp/wrapper.c; the path
 * translation used to live in per-tool shell shims on the Unix side.
 * Deliberately no win32 API use (wine_get_unix_file_name would do
 * the same job but needs wine's windows.h, absent in runtime-only
 * wine packages); dosdevices symlinks carry the same mapping.
 */
#include <stdio.h>
#include <spawn.h>
#include <errno.h>
#include <ctype.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

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
    int rc, wstatus;

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

    rc = posix_spawnp(&child, argv[0], NULL, NULL, argv, envp);
    if (rc) {
        errno = rc;
        perror("forwarder: posix_spawnp");
        return 255;
    }
    for (;;) {
        pid_t wr = waitpid(child, &wstatus, 0);
        if (wr == -1) {
            if (errno != EINTR)
                return 255;
            continue;
        }
        if (WIFEXITED(wstatus))
            return WEXITSTATUS(wstatus);
        if (WIFSIGNALED(wstatus))
            return 128 + WTERMSIG(wstatus);
    }
}
