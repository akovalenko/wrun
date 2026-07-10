#!/bin/sh
# gen-toolchain.sh — populate toolchain/<triplet>/ with bare-named
# wrapper scripts (gcc, ld, windres, ar, ...) over a cross toolchain.
# The directory is prepended to PATH by the build wrappers (wbuild.sh,
# qbuild.sh), so everything the SBCL runtime Makefiles might call
# resolves to the cross toolchain uniformly — no per-tool wiring, no
# changes to the SBCL tree.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TRIPLET="${WRUN_TRIPLET:-x86_64-w64-mingw32}"
FARM="$HERE/toolchain/$TRIPLET"

# Locate the cross gcc: the bare triplet name, or the highest
# versioned one (Ubuntu ships only aarch64-linux-gnu-gcc-12 & co.).
gcc_path=$(command -v "$TRIPLET-gcc") || {
    best=
    oldIFS=$IFS; IFS=:
    for d in $PATH; do
        for c in "${d:-.}/$TRIPLET"-gcc-[0-9]*; do
            [ -x "$c" ] || continue
            if [ -z "$best" ] || [ "${c##*-}" -gt "${best##*-}" ] 2>/dev/null
            then best=$c; fi
        done
    done
    IFS=$oldIFS
    gcc_path=$best
}
[ -n "$gcc_path" ] || {
    echo "gen-toolchain.sh: no $TRIPLET-gcc (nor $TRIPLET-gcc-<N>) in PATH" >&2
    exit 1; }
tooldir=$(dirname "$gcc_path")

mkdir -p "$FARM"
# Wrapper scripts, NOT symlinks: gcc invoked through a foreign-named
# symlink loses its cc1 under the forwarder environment (argv[0]-based
# subprogram discovery); `exec <absolute path>` keeps the driver
# self-locating regardless of caller and environment.
wrap() {
    printf '#!/bin/sh\nexec %s "$@"\n' "$1" > "$FARM/$2"
    chmod +x "$FARM/$2"
}
for tool in "$tooldir/$TRIPLET"-*; do
    [ -e "$tool" ] || continue
    base=${tool##*/}
    name=${base#"$TRIPLET"-}
    wrap "$tool" "$name"
    # Versioned-only tools: also provide the plain name (gcc-12 ->
    # gcc) unless a real unversioned tool claims it.
    plain=${name%-[0-9]*}
    [ "$plain" = "$name" ] || [ -e "$tooldir/$TRIPLET-$plain" ] || wrap "$tool" "$plain"
done
# The selected driver wins the bare-gcc seat (glob order is not
# version order); make-target-contrib.sh defaults CC to plain "cc".
[ -e "$tooldir/$TRIPLET-gcc" ] || wrap "$gcc_path" gcc
wrap "$gcc_path" cc

case "$TRIPLET" in *mingw*)
# cat wrapper: the contrib build concatenates module fasls with a
# Unix-side cat over a file list PRINTED BY THE TARGET LISP — under
# Wine those are Windows namestrings ("Z:/home/...").  Strip the
# drive prefix (Z: maps to /) and normalize backslashes before
# delegating to the real cat.  (Anton's original ~/shim/mingw/cat.)
cat > "$FARM/cat" <<'EOF'
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
chmod +x "$FARM/cat"
;; esac
ls "$FARM"
