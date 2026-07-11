#!/bin/sh
# abuild.sh — build SBCL for Android on a Linux host: no device, no
# adb, and no patches — a pure upstream "linux flavor against bionic"
# cross build.
#
# Upstream's own android path (--with-android) is not used at all: it
# hard-wires adb as the target executor (probes, arch detection,
# make-android.sh pushing the tree to a device).  Left unset, the
# whole adb machinery stays dormant, and the build becomes an
# ordinary qemu-profile cross build whose compiler is the NDK clang
# and whose runner executes target binaries under qemu-user against a
# donor Android runtime (see android-run).  The target OS really is
# Linux, so there is no SBCL_OS override and make-config's probes
# measure the actual bionic — os-provides-* features come out honest
# for the chosen API level.
#
# Usage: abuild.sh /path/to/sbcl-tree [extra make.sh args...]
#        abuild.sh /path/to/sbcl-tree --run [sbcl options...]
#        abuild.sh /path/to/sbcl-tree --tests [run-tests.sh args...]
#
# Requires: an Android NDK, a RECENT qemu-user (>= 10.x, see README),
# a host SBCL >= 2.5, an SBCL tree with SBCL_RUNNER support, and a
# donor Android runtime tree (system/bin/linker64 + system/lib64/*,
# e.g. termux's aosp-libs package unpacked).
#
# Knobs (environment); the defaults build arm64 against API 26:
#   WRUN_NDK          Android NDK root           (required on first run)
#   WRUN_ANDROID_API  targeted API level          [26]
#   WRUN_ARCH         make.sh --arch value        [arm64]
#   WRUN_TRIPLET      NDK target triplet          [aarch64-linux-android]
#   WRUN_QEMU         qemu-user binary            [qemu-aarch64]
#   WRUN_BIONIC       donor Android runtime root  (required without WRUN_DEVICE)
#
# Device profile: set WRUN_DEVICE to an ssh destination and the target
# phases run on a real Android device instead of qemu (see device-run
# for the mechanism and the WRUN_DEVICE_* / WRUN_SSH_* knobs); qemu and
# the donor runtime are then not needed at all.  The NDK farm still
# cross-compiles the C runtime on the host in both profiles.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
tree="$1"; shift

# Same degenerate-HOME rake as qbuild.sh (keep-id containers).
case "${HOME:-}" in
    ""|/) HOME=/tmp/wrun-home; mkdir -p "$HOME"; export HOME ;;
esac

: "${WRUN_ARCH:=arm64}"
: "${WRUN_TRIPLET:=aarch64-linux-android}"
: "${WRUN_ANDROID_API:=26}"
if [ -n "${WRUN_DEVICE:-}" ]; then
    # Real-device profile: target binaries run on the device over ssh
    # (sync-then-run, see device-run); qemu and the donor runtime stay
    # out of the picture.
    WRUN_TREE=$(cd "$tree" && pwd); export WRUN_TREE
    # Keep the device awake for the duration of the build (best
    # effort; termux-specific, harmless elsewhere).
    ssh ${WRUN_SSH_OPTS:-} -n "$WRUN_DEVICE" termux-wake-lock 2>/dev/null || true
else
    : "${WRUN_QEMU:=qemu-aarch64}"
    : "${WRUN_BIONIC:?donor Android runtime root (system/bin/linker64 + system/lib64)}"
    export WRUN_QEMU WRUN_BIONIC
fi

# NDK clang farm under bare names, generated on first use.  The API
# level is baked into the wrappers; rerun gen-toolchain.sh to change
# it for a triplet.
[ -x "$HERE/toolchain/$WRUN_TRIPLET/gcc" ] || \
    WRUN_TRIPLET="$WRUN_TRIPLET" WRUN_NDK="${WRUN_NDK:-}" \
    WRUN_ANDROID_API="$WRUN_ANDROID_API" \
    sh "$HERE/gen-toolchain.sh"
PATH="$HERE/toolchain/$WRUN_TRIPLET:$PATH"
export PATH

if [ -n "${WRUN_DEVICE:-}" ]; then
    export SBCL_RUNNER="$HERE/device-run"
else
    export SBCL_RUNNER="$HERE/android-run"
fi

# --without-gcc-tls below API 29 only: NDK clang there compiles
# __thread into EMULATED TLS (__emutls_v.* + __emutls_get_address),
# which cannot satisfy the runtime's direct references to the
# current_thread TLS symbol — the link dies with "undefined symbol:
# current_thread".  Upstream's own android recipe (make-android.sh)
# disables the feature the same way; so does termux.  From API 29 on
# bionic's linker supports ELF TLS, clang emits real TLS, and
# :gcc-tls stays in (an explicit make.sh flag in "$@" still wins —
# abuild's own flag comes first).
tls=
[ "$WRUN_ANDROID_API" -lt 29 ] && tls=--without-gcc-tls
cd "$tree"
# --run / --tests: run-sbcl.sh / the regression suite under the
# build's own environment (runner, NDK farm on PATH) — see wbuild.sh.
# Qemu profile: pure tests only, impure/sh tests re-exec the target
# lisp from itself (guest-exec-guest needs binfmt_misc).  Device
# profile: the whole suite runs natively on the device.
case "${1:-}" in
    --run) shift; exec sh run-sbcl.sh "$@" ;;
    --tests)
        shift
        WRUN_RUNTIME="$PWD/src/runtime/sbcl"
        TEST_SBCL_RUNTIME="$HERE/target-sbcl"
        export WRUN_RUNTIME TEST_SBCL_RUNTIME
        cd tests
        exec sh run-tests.sh "$@" ;;
esac
exec sh make.sh --arch="$WRUN_ARCH" $tls "$@"
