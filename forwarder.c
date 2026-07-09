/* forwarder — winelib bridge from the Wine world to build-host tools.
 *
 * Build (needs winegcc from wine devel tools):
 *     winegcc -o a.out forwarder.c        # produces a.out + a.out.so
 *
 * Install: symlink <tool>.exe -> a.out.so (see gen-shims.sh) in a
 * directory listed in WINEPATH.  When a Windows process (e.g. SBCL's
 * run-program) does CreateProcess("<tool>.exe", ...), Wine loads this
 * winelib program instead.  It:
 *   1. strips the directory and ".exe" suffix from argv[0],
 *   2. rewrites Windows-absolute-path arguments ("Z:\home\...") into
 *      Unix form via wine_get_unix_file_name(),
 *   3. posix_spawnp()s the real <tool> from the Unix PATH, forwarding
 *      stdio and returning its exit status.
 *
 * Descendant of Anton Kovalenko's runp/wrapper.c; the path
 * translation used to live in per-tool shell shims on the Unix side.
 */
#include <stdio.h>
#include <spawn.h>
#include <errno.h>
#include <ctype.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <windows.h>

#ifndef CP_UNIXCP                /* wine-specific; absent in plain w32api */
#define CP_UNIXCP 65010
#endif

static char * (CDECL *p_wine_get_unix_file_name)(LPCWSTR);

static void find_translator(void)
{
    HMODULE k32 = GetModuleHandleA("kernel32.dll");
    if (k32)
        p_wine_get_unix_file_name =
            (void *)GetProcAddress(k32, "wine_get_unix_file_name");
}

/* "Z:\foo" / "c:/bar" -> "/unix/path"; anything else unchanged. */
static char *maybe_translate(char *arg)
{
    WCHAR wbuf[4096];
    char *unix_name;

    if (!(isalpha((unsigned char)arg[0]) && arg[1] == ':'
          && (arg[2] == '\\' || arg[2] == '/')))
        return arg;
    if (!p_wine_get_unix_file_name)
        return arg;
    if (!MultiByteToWideChar(CP_UNIXCP, 0, arg, -1, wbuf, 4096))
        return arg;
    unix_name = p_wine_get_unix_file_name(wbuf);
    return unix_name ? unix_name : arg;
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

    find_translator();
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
