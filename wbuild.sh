#!/bin/sh
# wbuild.sh — build SBCL for x86-64 Windows on a Linux host.
#
# Usage: wbuild.sh /path/to/sbcl-tree [extra make.sh args...]
#        wbuild.sh /path/to/sbcl-tree --run [sbcl options...]
#        wbuild.sh /path/to/sbcl-tree --tests [run-tests.sh args...]
#
# Requires: mingw-w64 cross gcc, wine, a host SBCL, and an SBCL tree
# with the SBCL_OS/SBCL_RUNNER support (see README).  Run `make`
# first (forwarder + shims + toolchain dir).  WINEPREFIX is respected
# if set; the default is ~/.wine-wrun (wine creates it on first use).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
tree="$1"; shift

# Under rootless podman with --userns=keep-id the user has no passwd
# entry: HOME comes out unset or "/" and wine would try /.wine.  The
# replacement must be a directory OWNED by the build uid — wine
# refuses to create a prefix under root-owned /tmp itself.
case "${HOME:-}" in
    ""|/) HOME=/tmp/wrun-home; mkdir -p "$HOME"; export HOME ;;
esac
: "${WINEPREFIX:=$HOME/.wine-wrun}"
export WINEPREFIX
# Modern wine keeps the wineserver socket under XDG_RUNTIME_DIR and
# complains when it is unset/invalid (no /run/user/<uid> in a
# container).  Per the XDG spec it must be OURS and mode 0700.
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ] || [ ! -w "$XDG_RUNTIME_DIR" ]; then
    XDG_RUNTIME_DIR="$HOME/.xdg-run"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    export XDG_RUNTIME_DIR
fi

# Cross toolchain under bare names (gcc, ld, windres, ...) — shadows
# the host toolchain for the duration of the build.
TRIPLET="${WRUN_TRIPLET:-x86_64-w64-mingw32}"
PATH="$HERE/toolchain/$TRIPLET:$PATH"
export PATH

export SBCL_OS=win32
export SBCL_RUNNER="$HERE/wine-run"
export WINEDEBUG="${WINEDEBUG:--all}"
# Make the shim farm visible to CreateProcess in the Wine world, for
# run-program spawns from the target lisp (sb-grovel's $CC etc.).
WINEPATH="$("${WINE:-wine}" winepath -w "$HERE/shims")"
export WINEPATH

cd "$tree"
# --run / --tests instead of make.sh args: poke or test the freshly-
# built target in the very environment the build had.  run-sbcl.sh
# honors SBCL_RUNNER, and run-program spawns from the target lisp
# (sb-grovel's $CC, the suite's `sh`) keep resolving through the shims
# to Unix tools — the forwarder spawns bare tool names via the Unix
# PATH set up above.  For the suite, tests/subr.sh takes its "runtime"
# from TEST_SBCL_RUNTIME: the target-sbcl stand-in reattaches the
# runner, and WRUN_RUNTIME pins the runtime this profile builds
# (subr.sh itself would guess .exe-if-present — ambiguous in a tree
# carrying both targets).
case "${1:-}" in
    --run) shift; exec sh run-sbcl.sh "$@" ;;
    --tests)
        shift
        WRUN_RUNTIME="$PWD/src/runtime/sbcl.exe"
        TEST_SBCL_RUNTIME="$HERE/target-sbcl"
        export WRUN_RUNTIME TEST_SBCL_RUNTIME
        cd tests
        exec sh run-tests.sh "$@" ;;
esac
exec sh make.sh --arch=x86-64 "$@"
