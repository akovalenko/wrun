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
   `Z:\...`-style absolute path arguments to Unix form
   (`wine_get_unix_file_name`), and `posix_spawnp`s the real tool.
   The default manifest (`shims.list`) contains just the cross gcc
   (for sb-grovel) and `cat`.
3. **`toolchain/`**: bare-named symlinks (`gcc`, `ld`, `windres`,
   `ar`, ...) to the mingw-w64 cross tools, prepended to `PATH` for
   the duration of the build.  One directory uniformly covers every
   tool the runtime Makefiles call, with zero changes to the SBCL
   tree (deliberately kept this way to keep the upstream patch
   small).  The target OS is `SBCL_OS=win32` — no fake `uname`.

`wbuild.sh` wires all of this together.

## Prerequisites

- mingw-w64 cross gcc (`x86_64-w64-mingw32-gcc`) — prefer a recent
  one: old mingw-w64 headers lack declarations for newer win32 APIs
  (`WaitOnAddress` & co.), and the build then "works by accident"
  through implicit declarations;
- wine (tested with 6.0.3; anything newer should do) and winegcc
  (wine devel package) to build the forwarder;
- a host SBCL for the cross-compilation phases;
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

## The same runner hook without Wine

`SBCL_RUNNER` is emulator-agnostic.  For a full foreign-architecture
Linux build without hardware:

```sh
SBCL_RUNNER="qemu-aarch64 -L /usr/aarch64-linux-gnu" \
CC=aarch64-linux-gnu-gcc SBCL_OS=linux \
sh make.sh --arch=arm64
```

(qemu-user needs no daemon, no privileges, no binfmt.)

## Status / provenance

Grown out of Anton Kovalenko's long-lived local setup (mingw + wine +
ad-hoc shims re-ported onto every SBCL master).  This kit replaces
the per-branch patching with an upstreamable hook and replaces the
per-tool shell shims with one argv[0]-dispatching forwarder.
