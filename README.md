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
./wbuild.sh ~/src/sbcl --run     # poke the result: a REPL via run-sbcl.sh
./wbuild.sh ~/src/sbcl --tests   # the regression suite via tests/run-tests.sh
```

`--run` (every build script has it) execs the tree's `run-sbcl.sh`
instead of `make.sh`, under the exact environment the build had —
the runner, the wine prefix, and the toolchain farm on `PATH` — so
poking that compiles C on the fly (sb-grovel contribs) keeps using
the cross compiler through the shims.  Extra arguments after `--run`
are passed to SBCL.

`--tests` (same idea) runs the regression suite: `tests/run-tests.sh`
under the build environment, with the suite's runtime swapped via its
own `TEST_SBCL_RUNTIME` knob to a stand-in (`target-sbcl`) that
reattaches the runner — no changes to the SBCL tree involved.
Arguments pass through to `run-tests.sh`; naming files selects them,
and contrib tests are ordinary suite files: `--tests
sb-posix.impure.lisp`.  `--tests pure` / `--tests impure` select the
two halves of the suite: pure runs inside the test driver itself,
impure (sh tests included) is the self-spawning half.  Caveat for
the emulated profiles: impure and
sh tests re-exec the target lisp *from itself*, which works under
Wine (`CreateProcess` inside the Wine world) and on a real device
(native), but not under qemu-user without `binfmt_misc` — there only
the pure half of the suite runs.  Under Wine the sh tests run
through the `sh` shim (`SHELL` is pointed at it), with the Windows
environment bridged across (see forwarder.c); the few that exec a
binary they just dumped (`./foo.core`) still fail honestly — a Unix
`sh` cannot exec a Windows PE without `binfmt_misc`.

Useful knobs (environment): `WINEPREFIX` (defaults to
`~/.wine-wrun`), `WINE`, `WINEDEBUG` (defaults to `-all`),
`WRUN_TRIPLET` (defaults to `x86_64-w64-mingw32`),
`SBCL_MAKE_JOBS=-j4`.

## Container (fresh toolchain, reproducible)

The included `Containerfile` builds an Arch-based image with current
wine, mingw-w64, a host SBCL and the qemu-user toolchain:

```sh
podman build -t wrun .
podman run --rm -v ~/src/sbcl:/src --userns=keep-id wrun /src
podman run --rm -it -v ~/src/sbcl:/src --userns=keep-id wrun /src --run
podman run --rm -v ~/src/sbcl:/src --userns=keep-id wrun /src --tests pure
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

## Android targets: the abuild profile — no device, no adb

Upstream's own Android path hard-wires adb as the target executor
(probes, arch detection, `make-android.sh` pushing the whole tree to
a device).  `abuild.sh` doesn't use any of it: with `--with-android`
never passed, the adb machinery stays dormant, and the build is an
ordinary qemu-profile cross build — "linux flavor against bionic" —
whose compiler is the NDK clang and whose runner (`android-run`)
executes target binaries under qemu-user against a **donor Android
runtime**: a directory with `system/bin/linker64` and
`system/lib64/*.so`, e.g. termux's `aosp-libs` package unpacked, or
an emulator system image.  The target OS really is Linux, so no
`SBCL_OS` override; make-config's probes run under qemu against the
actual bionic, and the `os-provides-*` features come out honest for
the chosen API level.

```sh
WRUN_NDK=~/android-ndk-r29 WRUN_BIONIC=~/bionic-root \
    ./abuild.sh ~/src/sbcl    # arm64 against API 26 by default
```

Knobs (environment): `WRUN_NDK`, `WRUN_ANDROID_API`, `WRUN_ARCH`,
`WRUN_TRIPLET`, `WRUN_QEMU`, `WRUN_BIONIC` — see the header of
`abuild.sh`.  The toolchain farm covers the differences between the
GNU-style cross toolchain and the NDK: bare names map onto the
per-API clang driver and llvm binutils, empty `libpthread.a`/
`librt.a` stubs satisfy `Config.*-linux` (bionic keeps both in
libc), and the driver wrappers plug the one C-level glibc-ism the
"linux" sources use that bionic never had (`getdtablesize`).
`abuild.sh` always passes `--without-gcc-tls`: NDK clang below API
29 compiles `__thread` into *emulated* TLS (`__emutls_v.*`), which
cannot satisfy the runtime's direct references to the
`current_thread` TLS symbol — upstream's own `make-android.sh`
disables the feature the same way.
`Containerfile.android` packages the whole profile (NDK + static
qemu + aosp-libs donor + host SBCL) into a self-contained image.

Note the donor's API ceiling: binaries built for `WRUN_ANDROID_API`
N need a bionic >= N to run, and the aosp-libs donor is Android 9
(API 28).  The default API 26 keeps `getpwent` & co. available to
sb-posix while staying comfortably under that ceiling.

### The device profile: offload target phases to a real device

Set `WRUN_DEVICE` to an ssh destination (an `ssh_config` alias is the
comfortable form) and `abuild.sh` swaps the runner: instead of
qemu-user, every target-binary invocation runs **on the device**
(`device-run`) — the tree is mirrored there with rsync before the
run (incremental, one exact mirror per tree), the binary executes in
the same tree-relative cwd over a multiplexed ssh connection
(stdin/stdout/stderr and the exit code pass through), and the
products come back with a second rsync.  qemu and the donor runtime
are not needed at all; the NDK farm still cross-compiles the C
runtime on the host.  The build stays host-orchestrated — the device
is an optional accelerator, not a dependency (unplug it and the qemu
profile is one unset variable away).

```sh
WRUN_NDK=~/android-ndk-r29 WRUN_DEVICE=phone \
WRUN_SSH_OPTS='-F ~/.ssh/config.devices' \
    ./abuild.sh ~/src/sbcl
```

Knobs: `WRUN_DEVICE`, `WRUN_SSH_OPTS`, `WRUN_DEVICE_DIR`,
`WRUN_DEVICE_CC`, `WRUN_SSH_CTL` — see the header of `device-run`.
Details worth knowing:

- the remote process runs with `SBCL_RUNNER` unset (target binaries
  are native there, so the in-lisp grovel helpers exec their
  `a.out` directly) and with `CC` overridden by `WRUN_DEVICE_CC`
  (default `clang`, present on termux): sb-grovel then compiles and
  runs its probe program against the device's **real** libc;
- per-invocation overhead is two rsync scans plus a mux'd ssh
  channel — a few seconds; the first push pays for the whole tree;
- `abuild.sh` takes a `termux-wake-lock` on the device for the
  build's duration (best effort, harmless elsewhere);
- the pull is `-u` (receiver-newer wins): the build scripts redirect
  the runner's stdout into the tree (`determine-endianness >> $ltf`),
  and a plain pull would revert such files to the pre-run device
  copy.  `-u` rides on mtimes across two clocks, so the runner
  hard-fails on host/device skew above 30 s — keep the device
  NTP-synced (fasl mtimes carry the device clock anyway);
- `WRUN_SSH_OPTS` values with embedded spaces in paths are not
  supported (the runner word-splits them);
- `WRUN_STATS=<file>` appends one line per invocation —
  `<push-ms> <run-ms> <pull-ms> <argv0>` — so a build timing can
  subtract the network share (stop worrying whether the link was
  wifi or lte).  Summarize with:

  ```sh
  awk '{p+=$1;r+=$2;l+=$3;n++} END{printf \
      "n=%d push=%.1fs run=%.1fs pull=%.1fs sync-total=%.1fs\n", \
      n, p/1e3, r/1e3, l/1e3, (p+l)/1e3}' "$WRUN_STATS"
  ```

  `run` still contains the mux'd ssh channel latency (hundreds of
  ms per invocation), which no realistic link turns into minutes.

## Status / provenance

Grown out of Anton Kovalenko's long-lived local setup (mingw + wine +
ad-hoc shims re-ported onto every SBCL master).  This kit replaces
the per-branch patching with an upstreamable hook and replaces the
per-tool shell shims with one argv[0]-dispatching forwarder.
