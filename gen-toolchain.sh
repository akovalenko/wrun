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
# Wrapper scripts, NOT symlinks: gcc invoked through a foreign-named
# symlink loses its cc1 under the forwarder environment (argv[0]-based
# subprogram discovery); `exec <absolute path>` keeps the driver
# self-locating regardless of caller and environment.
wrap() {
    printf '#!/bin/sh\nexec %s "$@"\n' "$1" > "$HERE/toolchain/$2"
    chmod +x "$HERE/toolchain/$2"
}
for tool in "$tooldir/$TRIPLET"-*; do
    [ -e "$tool" ] || continue
    base=${tool##*/}
    wrap "$tool" "${base#"$TRIPLET"-}"
done
# make-target-contrib.sh defaults CC to plain "cc" on some paths
wrap "$gcc_path" cc

# cat wrapper: the contrib build concatenates module fasls with a
# Unix-side cat over a file list PRINTED BY THE TARGET LISP — under
# Wine those are Windows namestrings ("Z:/home/...").  Strip the
# drive prefix (Z: maps to /) and normalize backslashes before
# delegating to the real cat.  (Anton's original ~/shim/mingw/cat.)
cat > "$HERE/toolchain/cat" <<'EOF'
#!/bin/sh
n=$#; i=0
while [ $i -lt $n ]; do
    f=$1; shift
    case "$f" in
        [A-Za-z]:*) f=$(printf '%s' "$f" | tr '\\' '/'); f=${f#??} ;;
    esac
    set -- "$@" "$f"
    i=$((i+1))
done
exec /bin/cat "$@"
EOF
chmod +x "$HERE/toolchain/cat"
ls "$HERE/toolchain"
