#!/usr/bin/env bash
#
# build-examples.sh — build the examples against the shim's XForms build.
#
# The page documents the build as a single command:
#
#     cc -o xftest xftest.c -lforms -lX11
#
# so that is exactly what is used.  libforms comes from the XForms build tree and
# libX11 from the shim prefix.
#
# xftest1-3 are the three programs from that page.  xftest4 is local: it covers a
# borderless form with a menu bar, a shape the three from the page do not reach.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MW_PREFIX="${MW_PREFIX:-$HOME/.local/motif-wayland}"
XFORMS_SRC="${XFORMS_SRC:-$HOME/src/xforms/xforms-1.2.4}"
XFORMS_PREFIX="${XFORMS_PREFIX:-$HOME/.local/xforms}"

# libforms comes from the installed XForms tree (headers and .so), libX11 from
# the shim prefix.  The rpaths mean the binaries need no LD_LIBRARY_PATH.
for n in xftest1 xftest2 xftest3 xftest4; do
    cc -O2 -I"$XFORMS_PREFIX/include" -o "$HERE/$n" "$HERE/$n.c" \
       -L"$XFORMS_PREFIX/lib" -lforms \
       -L"$MW_PREFIX/lib" -lX11 \
       -Wl,-rpath,"$XFORMS_PREFIX/lib" -Wl,-rpath,"$MW_PREFIX/lib"
    echo "built $HERE/$n"
done