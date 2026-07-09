#!/bin/sh
# wbuild.sh — build SBCL for x86-64 Windows on a Linux host.
#
# Usage: wbuild.sh /path/to/sbcl-tree [extra make.sh args...]
#
# Requires: mingw-w64 cross gcc, wine, a host SBCL, and an SBCL tree
# with the SBCL_OS/SBCL_RUNNER support (see README).  Run `make`
# first (forwarder + shims + toolchain dir).  WINEPREFIX is respected
# if set; wine creates a default one otherwise.
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
PATH="$HERE/toolchain:$PATH"
export PATH

export SBCL_OS=win32
export SBCL_RUNNER="$HERE/wine-run"
export WINEDEBUG="${WINEDEBUG:--all}"
# Make the shim farm visible to CreateProcess in the Wine world, for
# run-program spawns from the target lisp (sb-grovel's $CC etc.).
WINEPATH="$("${WINE:-wine}" winepath -w "$HERE/shims")"
export WINEPATH

cd "$tree"
exec sh make.sh --arch=x86-64 "$@"
