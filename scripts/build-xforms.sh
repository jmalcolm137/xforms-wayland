#!/usr/bin/env bash
#
# build-xforms.sh — build XForms unmodified against the xlib-wayland shim.
#
# XForms is a pure-Xlib widget toolkit: it links libXpm and libX11 and nothing else.
# The shim is installed as libX11.so.6, so all this script does is point the link
# at it (-L/-rpath) and let the upstream configure/make run untouched.
#
# No source edits are made.  Two host-compiler accommodations are passed as flags,
# in the same spirit as NEdit's -std=gnu89 -fcommon in the parent project:
#
#   -fcommon   XForms predates C23 and relies on tentative definitions
#              (`int curobj;` in both fdesign/sp_twheel.c and sp_spinner.c), which
#              GCC >= 10 rejects by default with -fno-common.
#   -I/usr/include
#              The shim installs no headers -- there is nothing in the Xlib API it
#              does not implement -- so we compile against the system X11 headers,
#              which are ABI-compatible with the shim by construction.
#
# Usage: build-xforms.sh [--prefix=DIR] [--jobs=N] [--skip-configure] [--install]
#
# Environment:
#   MW_PREFIX     shim prefix                 (default: $HOME/.local/motif-wayland)
#   XFORMS_PREFIX XForms install prefix       (default: $HOME/.local/xforms)
#   XFORMS_SRC    unpacked XForms tree       (default: $HOME/src/xforms/xforms-1.2.4)
#   JOBS          parallel make jobs         (default: nproc)
set -euo pipefail

MW_PREFIX="${MW_PREFIX:-$HOME/.local/motif-wayland}"
XFORMS_PREFIX="${XFORMS_PREFIX:-$HOME/.local/xforms}"
XFORMS_SRC="${XFORMS_SRC:-$HOME/src/xforms/xforms-1.2.4}"
JOBS="${JOBS:-$(nproc)}"
do_install=0; do_configure=1

for a in "$@"; do
    case "$a" in
        --prefix=*)   XFORMS_PREFIX="${a#*=}" ;;
        --jobs=*)     JOBS="${a#*=}" ;;
        --src=*)      XFORMS_SRC="${a#*=}" ;;
        --skip-configure) do_configure=0 ;;
        --install)    do_install=1 ;;
        -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

# Same guard as the parent's build-stack.sh: without the shim installed, XForms
# would link against the system X11 and "work" under XWayland, which is exactly
# the mistake this project exists to avoid.
[ -e "$MW_PREFIX/lib/libX11.so" ] || {
    echo "missing $MW_PREFIX/lib/libX11.so -- build the shim first:" >&2
    echo "  (cd \$MW_SRC && meson setup build --prefix=\"\$MW_PREFIX\" && meson install -C build)" >&2
    exit 1; }

[ -d "$XFORMS_SRC" ] || { echo "no XForms source at $XFORMS_SRC" >&2; exit 1; }

cd "$XFORMS_SRC"
if [ "$do_configure" -eq 1 ]; then
    echo "== configuring XForms against $MW_PREFIX/lib"
    # --enable-demos  the 94 programs in demos/ are the test corpus (DESIGN.md 5.2);
    #                 without it `make` builds only the library, fdesign and xfd.
    # --disable-gl    the GL demos call GLX directly, which is not a Wayland thing
    #                 (DESIGN.md 1.2); dropping the GL support library keeps them
    #                 out of the build instead of letting them fail to link.
    # -Wl,-rpath bakes the shim in, so installed binaries need no
    # LD_LIBRARY_PATH and can never fall back to the system X11.
    ./configure --prefix="$XFORMS_PREFIX" --enable-demos --disable-gl \
                CFLAGS="-O2 -fcommon -I/usr/include" \
                LDFLAGS="-L$MW_PREFIX/lib -Wl,-rpath,$MW_PREFIX/lib"
fi

echo "== make -j$JOBS"
make -j"$JOBS"

if [ "$do_install" -eq 1 ]; then
    echo "== make install -> $XFORMS_PREFIX"
    make install
fi

echo
echo "library : $XFORMS_SRC/lib/.libs/libforms.so"
echo "demos   : $XFORMS_SRC/demos/.libs/"
echo "run one : LD_LIBRARY_PATH=$MW_PREFIX/lib $XFORMS_SRC/demos/buttonall"