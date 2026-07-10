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

# Android triplets come from the NDK: one clang driver per (triplet,
# API level) plus llvm binutils, no GNU-style $TRIPLET-* tools at all.
# The farm path stays per-triplet only, so the API level is baked into
# the wrappers — rerun this script to change WRUN_ANDROID_API for a
# triplet (same caveat as WRUN_SYSROOT below).
case "$TRIPLET" in *-android*)
    [ -n "${WRUN_NDK:-}" ] || {
        echo "gen-toolchain.sh: WRUN_NDK (NDK root) is required for $TRIPLET" >&2
        exit 1; }
    API="${WRUN_ANDROID_API:-26}"
    ndkbin="$WRUN_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
    driver="$ndkbin/$TRIPLET$API-clang"
    [ -x "$driver" ] || {
        echo "gen-toolchain.sh: no $driver in the NDK" >&2
        exit 1; }
    mkdir -p "$FARM"
    # Config.*-linux links with -lpthread/-lrt (bionic keeps both in
    # libc); if this NDK ships no stub archives for them, provide
    # empty ones and bake -L into the driver wrappers.
    sysdir="$WRUN_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$TRIPLET"
    extra=
    if [ ! -e "$sysdir/libpthread.a" ] && [ ! -e "$sysdir/$API/libpthread.a" ]; then
        mkdir -p "$FARM/stubs"
        "$ndkbin/llvm-ar" rcs "$FARM/stubs/libpthread.a"
        "$ndkbin/llvm-ar" rcs "$FARM/stubs/librt.a"
        extra=" -L$FARM/stubs"
    fi
    # The C-level glibc-isms "linux flavor against bionic" trips over
    # (upstream guards both with the :android Lisp feature we
    # deliberately don't set; a full include-sweep of the runtime
    # sources against the NDK sysroot found nothing else):
    #
    # - getdtablesize(), which bionic never had.  A function-like
    #   macro is the narrowest plug: safe to define everywhere,
    #   expands only at the call site (run-program.c, which includes
    #   <unistd.h> for sysconf anyway), and unlike -include it cannot
    #   corrupt .S preprocessing.
    # - <sys/termios.h> (grovel-headers.c), which glibc itself
    #   defines as exactly '#include <termios.h>' — a one-line compat
    #   header in the farm.
    extra="$extra -D'getdtablesize()=((int)sysconf(_SC_OPEN_MAX))'"
    mkdir -p "$FARM/include/sys"
    printf '#include <termios.h>\n' > "$FARM/include/sys/termios.h"
    extra="$extra -isystem $FARM/include"
    emit() {
        printf '#!/bin/sh\nexec %s%s "$@"\n' "$2" "$3" > "$FARM/$1"
        chmod +x "$FARM/$1"
    }
    for n in gcc cc clang;       do emit "$n" "$driver"   "$extra"; done
    for n in g++ c++ clang++;    do emit "$n" "${driver}++" "$extra"; done
    for t in ar ranlib nm strip objcopy objdump readelf strings; do
        [ -x "$ndkbin/llvm-$t" ] && emit "$t" "$ndkbin/llvm-$t" ""
    done
    ls "$FARM"
    exit 0
;; esac

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
#
# With WRUN_SYSROOT set, compiler-driver wrappers get --sysroot baked
# in (portable-dist builds: a sysroot-less cross gcc plus an old-glibc
# donor sysroot).  Binutils resolve paths via the driver, so only the
# drivers need it.  NOTE: the farm path is per-triplet only — rerun
# this script when changing WRUN_SYSROOT for a triplet.
is_driver() {
    case "$1" in
        gcc|g++|c++|cpp|cc) return 0 ;;
        gcc-[0-9]*|g++-[0-9]*|c++-[0-9]*|cpp-[0-9]*) return 0 ;;
    esac
    return 1
}
wrap() {
    if [ -n "${WRUN_SYSROOT:-}" ] && is_driver "$2"; then
        printf '#!/bin/sh\nexec %s --sysroot=%s "$@"\n' \
            "$1" "$WRUN_SYSROOT" > "$FARM/$2"
    else
        printf '#!/bin/sh\nexec %s "$@"\n' "$1" > "$FARM/$2"
    fi
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
