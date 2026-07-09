#!/bin/sh
# gen-toolchain.sh — populate toolchain/ with bare-named symlinks
# (gcc, ld, windres, ar, ...) to the mingw-w64 cross tools.  The
# directory is prepended to PATH by wbuild.sh, so everything the SBCL
# runtime Makefiles might call resolves to the cross toolchain
# uniformly — no per-tool wiring, no changes to the SBCL tree.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TRIPLET="${WRUN_TRIPLET:-x86_64-w64-mingw32}"

gcc_path=$(command -v "$TRIPLET-gcc") || {
    echo "gen-toolchain.sh: $TRIPLET-gcc not found in PATH" >&2; exit 1; }
tooldir=$(dirname "$gcc_path")

mkdir -p "$HERE/toolchain"
for tool in "$tooldir/$TRIPLET"-*; do
    [ -e "$tool" ] || continue
    base=${tool##*/}
    ln -sf "$tool" "$HERE/toolchain/${base#"$TRIPLET"-}"
done
# make-target-contrib.sh defaults CC to plain "cc" on some paths
ln -sf "$gcc_path" "$HERE/toolchain/cc"
ls "$HERE/toolchain"
