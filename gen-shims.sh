#!/bin/sh
# gen-shims.sh — populate shims/ with <tool>.exe symlinks to the
# forwarder, from the manifest shims.list (one tool name per line,
# comments with #).  The tool name must be resolvable in the Unix
# PATH at build time; run-program calls from the Wine world reach it
# through WINEPATH -> <tool>.exe -> forwarder -> posix_spawnp(<tool>).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HERE/shims"
[ -f "$HERE/a.out.so" ] || { echo "gen-shims.sh: build the forwarder first (make)" >&2; exit 1; }
cp -f "$HERE/a.out.so" "$HERE/shims/a.out.so"
grep -v '^[[:space:]]*\(#\|$\)' "$HERE/shims.list" | while read -r tool; do
    ln -sf a.out.so "$HERE/shims/$tool.exe"
done
ls -l "$HERE/shims"
