# Needs wine devel tools (winegcc).  `winegcc -o a.out` yields the
# launcher script a.out plus the winelib module a.out.so; the shim
# symlinks point at the .so (Wine loads it directly).
all: a.out shims toolchain

a.out: forwarder.c
	winegcc -o a.out forwarder.c

shims: a.out shims.list
	sh gen-shims.sh

toolchain:
	sh gen-toolchain.sh

clean:
	rm -rf a.out a.out.so shims toolchain
.PHONY: all shims toolchain clean
