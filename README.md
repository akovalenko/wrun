# wrun — build Windows SBCL on a Linux host, no MSYS, no VM

*(working name; everything here is provisional until first release)*

This kit builds a native Windows SBCL entirely on a Linux box:
the build scripts run in an ordinary POSIX environment, the C runtime
is compiled by mingw-w64 cross gcc, and Wine serves as the "CPU" for
the freshly-built *target* binaries only.  No MSYS/Cygwin layer, no
Windows VM, no `binfmt_misc` host configuration — the whole thing can
run inside an unprivileged CI container.

## How it works

Three small mechanisms, one per process-boundary:

1. **`wine-run`** (the `SBCL_RUNNER`): the SBCL build scripts prefix
   every execution of a just-built target binary with `$SBCL_RUNNER`.
   `wine-run` resolves the `.exe` suffix and execs `wine`.
2. **`forwarder.c`** (winelib): bridges `run-program` calls *from the
   target lisp* back to Unix tools.  `<tool>.exe` symlinks (in a
   directory listed in `WINEPATH`) all point at the forwarder, which
   strips the directory and `.exe` from `argv[0]`, converts
   `Z:\...`-style absolute path arguments to Unix form (resolving
   `$WINEPREFIX/dosdevices/<drive>:` — no wine headers needed, so the
   forwarder builds with bare winegcc), `posix_spawnp`s the real tool,
   and bridges its stdio: when the Wine parent redirects std handles
   to Windows pipes (`run-program` with lisp streams), those pipes
   live in wineserver and have no Unix fd here — Wine points fds 0/1
   at `/dev/null` — so the child runs on the forwarder's own pipes
   and per-stream pump threads copy bytes to/from the Windows std
   handles (a hand-declared sliver of kernel32; import stubs ship
   with every winegcc).  Unredirected streams keep plain Unix fd
   inheritance.  The default manifest (`shims.list`) contains just
   the compiler names sb-grovel may ask for and `cat`.
3. **`toolchain/<triplet>/`**: bare-named wrapper scripts (`gcc`,
   `ld`, `windres`, `ar`, ...) over the cross tools, prepended to
   `PATH` for the duration of the build.  One directory per target
   triplet uniformly covers every tool the runtime Makefiles call,
   with zero changes to the SBCL tree (deliberately kept this way to
   keep the upstream patch small).  Versioned-only cross tools
   (Ubuntu's `aarch64-linux-gnu-gcc-12`) get their plain names
   automatically.  The target OS is `SBCL_OS=win32` — no fake
   `uname`.

`wbuild.sh` wires all of this together.

## Prerequisites

- Windows target: mingw-w64 cross gcc (`x86_64-w64-mingw32-gcc`) —
  prefer a recent one: old mingw-w64 headers lack declarations for
  newer win32 APIs (`WaitOnAddress` & co.), and the build then
  "works by accident" through implicit declarations;
- Windows target: wine (tested with 6.0.3; anything newer should do)
  and winegcc (wine devel package) to build the forwarder;
- foreign-arch Linux target: cross gcc for the triplet and a recent
  qemu-user (>= 10.x; see below);
- a host SBCL for the cross-compilation phases (>= 2.5 for current
  master);
- an SBCL tree with `SBCL_OS`/`SBCL_RUNNER` support (patch series in
  preparation for upstream; until merged, apply it from here).

## Usage

```sh
make                       # build forwarder, generate shims/
./wbuild.sh ~/src/sbcl     # ... make.sh args if needed
```

Useful knobs (environment): `WINEPREFIX` (defaults to `~/.wine`),
`WINE`, `WINEDEBUG` (defaults to `-all`), `WRUN_TRIPLET` (defaults to
`x86_64-w64-mingw32`), `SBCL_MAKE_JOBS=-j4`.

## Container (fresh toolchain, reproducible)

The included `Containerfile` builds an Arch-based image with current
wine, mingw-w64, a host SBCL and the qemu-user toolchain:

```sh
podman build -t wrun .
podman run --rm -v ~/src/sbcl:/src --userns=keep-id wrun /src
```

The default entrypoint builds the Windows target.  The same image
covers the qemu profile (Arch's qemu-user is current, both toolchain
farms are pre-generated) — override the entrypoint:

```sh
podman run --rm -v ~/src/sbcl:/src --userns=keep-id \
    --entrypoint /opt/wrun/qbuild.sh wrun /src
```

Rootless podman suffices: no `--privileged`, no binfmt_misc — target
binaries always run through `SBCL_RUNNER`, never via the host kernel.
`--userns=keep-id` keeps files created in the mounted tree owned by
you.  Old mingw-w64 (e.g. Ubuntu LTS) lacks declarations for newer
win32 APIs (`WaitOnAddress` & co.) and builds them "by accident" via
implicit declarations; current gcc treats those as hard errors, so
the fresh image doubles as a correctness check.

## Portable Linux dists: the manylinux profile

`Containerfile.portable` builds a second image, based on
`quay.io/pypa/manylinux_2_28` (AlmaLinux 8, glibc 2.28): fresh
compilers against an OLD glibc, so the produced Linux SBCL binaries
run on any 2018+ distribution.  x86-64 builds use the image's
gcc-toolset-14 directly (a native build — no runner involved); arm64
goes through the qemu profile with EPEL's sysroot-less cross gcc
plus an old-glibc sysroot donated by the aarch64 flavor of the same
image.  The donor sysroot is baked into the farm wrappers via
`WRUN_SYSROOT` and doubles as the default qemu `-L` prefix, keeping
link-time and run-time views of the guest world identical.  Usage
examples are in the header of `Containerfile.portable`.

`WRUN_SYSROOT` works outside containers too: point it at any donor
sysroot and `gen-toolchain.sh` bakes `--sysroot` into the compiler
*driver* wrappers (binutils resolve paths through the driver; rerun
the script to change a triplet's sysroot).

## The same runner hook without Wine: qemu-user targets

`SBCL_RUNNER` is emulator-agnostic.  `qbuild.sh` drives a full
foreign-architecture Linux build with qemu-user as the target "CPU"
(no daemon, no privileges, no binfmt).  None of the wine shelf
applies — guest-to-host exec is native under qemu-user, so the
forwarder/shims are not involved and `make` is not a prerequisite;
the toolchain farm is generated on first use:

```sh
./qbuild.sh ~/src/sbcl     # arm64 by default; make.sh args accepted
```

Knobs (environment): `WRUN_ARCH`, `WRUN_TRIPLET`, `WRUN_QEMU`,
`WRUN_QEMU_PREFIX` — see the header of `qbuild.sh`.

The qemu-user *version* matters: 6.2 futex-livelocks threaded SBCL
outright, 7.2 fork-corrupts x86-64 guests (`run-program` stream
users); qemu >= 10.x is known good.  Arch ships a current one; on
older distributions build qemu-user statically from a release tag —
it takes minutes and has no runtime dependencies:

```sh
git clone --depth 1 -b v10.2.4 https://gitlab.com/qemu-project/qemu
cd qemu
./configure --target-list=aarch64-linux-user \
            --disable-docs --disable-tools --static
ninja -C build qemu-aarch64      # point WRUN_QEMU at the result
```

(Old host pythons, e.g. Ubuntu 22.04's 3.10, additionally need the
`tomli` module for meson: `pip install tomli` or its sources on
`PYTHONPATH`.)

## Status / provenance

Grown out of Anton Kovalenko's long-lived local setup (mingw + wine +
ad-hoc shims re-ported onto every SBCL master).  This kit replaces
the per-branch patching with an upstreamable hook and replaces the
per-tool shell shims with one argv[0]-dispatching forwarder.
