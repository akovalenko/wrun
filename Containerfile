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

# gcc: winegcc is a wrapper over the NATIVE compiler (the forwarder
# is a winelib ELF); mingw-w64-gcc does not pull it in.
RUN pacman -Syu --noconfirm --needed \
        gcc wine mingw-w64-gcc sbcl make git \
        aarch64-linux-gnu-gcc qemu-user \
    && pacman -Scc --noconfirm

COPY . /opt/wrun
# Forwarder (winegcc), shims/ and BOTH toolchain farms, pre-generated
# at image build time: at run time /opt/wrun is root-owned, so the
# keep-id build uid could not create a farm on first use.
RUN make -C /opt/wrun \
    && WRUN_TRIPLET=aarch64-linux-gnu sh /opt/wrun/gen-toolchain.sh

ENV WINEDEBUG=-all
ENTRYPOINT ["/opt/wrun/wbuild.sh"]
