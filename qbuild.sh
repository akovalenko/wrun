#!/bin/sh
# qbuild.sh — build SBCL for a foreign Linux architecture on a Linux
# host: build scripts and the cross toolchain run natively, qemu-user
# serves as the "CPU" for freshly-built target binaries only.
#
# Usage: qbuild.sh /path/to/sbcl-tree [extra make.sh args...]
#        qbuild.sh /path/to/sbcl-tree --run [sbcl options...]
#        qbuild.sh /path/to/sbcl-tree --tests [pure|impure] [run-tests.sh args...]
#
# Requires: a cross gcc for the target triplet, a RECENT qemu-user
# (6.2 futex-livelocks threaded SBCL; 7.2 fork-corrupts x86-64
# guests; 10.x is known good), a host SBCL >= 2.5, and an SBCL tree
# with SBCL_RUNNER support (see README).  No SBCL_OS override: the
# target OS is the host's own (linux -> linux), and none of the wine
# shelf (forwarder, shims, WINEPATH) applies — guest-to-host exec is
# native under qemu-user, so `make` is not a prerequisite.
#
# Knobs (environment); the defaults build arm64:
#   WRUN_ARCH         make.sh --arch value        [arm64]
#   WRUN_TRIPLET      cross toolchain triplet     [aarch64-linux-gnu]
#   WRUN_QEMU         qemu-user binary            [qemu-aarch64]
#   WRUN_QEMU_PREFIX  guest ELF prefix (qemu -L)  [/usr/$WRUN_TRIPLET]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
tree="$1"; shift

# Under rootless podman with --userns=keep-id the user has no passwd
# entry and HOME comes out unset or "/"; the contrib phase derives
# ASDF's XDG paths from HOME and dies on the degenerate value (same
# rake wbuild.sh hits with wine prefixes).
case "${HOME:-}" in
    ""|/) HOME=/tmp/wrun-home; mkdir -p "$HOME"; export HOME ;;
esac

: "${WRUN_ARCH:=arm64}"
: "${WRUN_TRIPLET:=aarch64-linux-gnu}"
: "${WRUN_QEMU:=qemu-aarch64}"
# With WRUN_SYSROOT (portable-dist: old-glibc donor sysroot baked into
# the compiler wrappers) the guest must run against the same tree, so
# it doubles as the qemu -L prefix by default.
: "${WRUN_QEMU_PREFIX:=${WRUN_SYSROOT:-/usr/$WRUN_TRIPLET}}"
export WRUN_QEMU WRUN_QEMU_PREFIX

# Cross toolchain under bare names, generated on first use.
[ -x "$HERE/toolchain/$WRUN_TRIPLET/gcc" ] || \
    WRUN_TRIPLET="$WRUN_TRIPLET" WRUN_SYSROOT="${WRUN_SYSROOT:-}" \
    sh "$HERE/gen-toolchain.sh"
PATH="$HERE/toolchain/$WRUN_TRIPLET:$PATH"
export PATH

export SBCL_RUNNER="$HERE/qemu-run"

cd "$tree"
# --run / --tests: run-sbcl.sh / the regression suite under the
# build's own environment (SBCL_RUNNER, toolchain farm on PATH) — see
# wbuild.sh.  Without binfmt_misc only the pure half of the suite can
# run here: impure and sh tests re-exec the target lisp FROM ITSELF,
# and guest-exec-guest is not a thing under plain qemu-user.
case "${1:-}" in
    --run) shift; exec sh run-sbcl.sh "$@" ;;
    --tests)
        shift
        WRUN_RUNTIME="$PWD/src/runtime/sbcl"
        TEST_SBCL_RUNTIME="$HERE/target-sbcl"
        export WRUN_RUNTIME TEST_SBCL_RUNTIME
        cd tests
        # `pure` / `impure` sugar — see wbuild.sh; here `pure` is the
        # half that can actually run without binfmt_misc.
        case "${1:-}" in
            pure) shift; set -- *.pure.lisp *.pure-cload.lisp "$@" ;;
            impure) shift; set -- --skip-to impure "$@" ;;
        esac
        exec sh run-tests.sh "$@" ;;
esac
exec sh make.sh --arch="$WRUN_ARCH" "$@"
