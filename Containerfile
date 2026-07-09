# Arch-based build box for wine-hosted (and qemu-hosted) SBCL
# cross-builds: fresh wine + fresh mingw-w64 + host sbcl in one image.
#
#   podman build -t wrun .
#   podman run --rm -v ~/src/sbcl:/src --userns=keep-id wrun /src
#
# Rootless podman, no --privileged, no binfmt_misc: target binaries
# run through SBCL_RUNNER (wine / qemu), never via the host kernel.
#
# Why Arch: never splits -dev packages (winegcc + wine headers ship
# with wine itself) and carries current mingw-w64 — old mingw headers
# lack declarations for newer win32 APIs (WaitOnAddress & co.), and
# such builds only "work by accident" through implicit declarations.
FROM docker.io/archlinux:latest

RUN pacman -Syu --noconfirm --needed \
        wine mingw-w64-gcc sbcl make git \
        aarch64-linux-gnu-gcc qemu-user \
    && pacman -Scc --noconfirm

COPY . /opt/wrun
# builds the forwarder (winegcc) and generates shims/ + toolchain/
RUN make -C /opt/wrun

ENV WINEDEBUG=-all
ENTRYPOINT ["/opt/wrun/wbuild.sh"]
