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
# entry: HOME comes out unset or "/" and wine would try /.wine.
case "${HOME:-}" in ""|/) HOME=/tmp; export HOME ;; esac
: "${WINEPREFIX:=$HOME/.wine-wrun}"
export WINEPREFIX

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
