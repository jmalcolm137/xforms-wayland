#!/usr/bin/env bash
#
# run-xforms-demos.sh — run the XForms bundled demos against the shim.
#
# The three examples from xforms-toolkit.org/examples.html (run by
# run-xforms-examples.sh) only exercise buttons.  The 90-odd programs in XForms'
# own demos/ directory are the real corpus: menus and override-redirect popups,
# Xpm pixmaps, bitmaps, fonts, text input and XIM, browsers with asyn I/O,
# canvas/chart drawing, timers and animation.
#
# Each demo runs under the bundled headless compositor with the shim first on the
# library path and is classified:
#
#   ok      mapped a window and painted something (more than one colour)
#   ran     started and stayed up but painted nothing
#   gap     needs an Xlib symbol the shim does not export
#   crash   died on a signal -- a shim defect, never acceptable
#
# The demos are interactive, so "stayed up until we killed it" is the expected
# outcome: the matrix is looking for crashes, missing symbols and blank windows,
# not for programs that exit.  Mouse handling is covered by
# run-xforms-examples.sh, which drives real click sequences.
#
# Usage: run-xforms-demos.sh [demo ...]      (default: the built-in list)
#
# Environment:
#   MW_BUILD     shim build directory (default: <repo>/xlib-wayland/build)
#   MW_PREFIX    shim prefix         (default: $HOME/.local/motif-wayland)
#   XFORMS_SRC   XForms source tree  (default: $HOME/src/xforms/xforms-1.2.4)
#   FRAMES       keep frames and logs here (default: a temp dir)
#   DEMO_SECS    seconds per demo    (default: 4)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="${MW_BUILD:-$ROOT/xlib-wayland/build}"
PREFIX="${MW_PREFIX:-$HOME/.local/motif-wayland}"
XFORMS_SRC="${XFORMS_SRC:-$HOME/src/xforms/xforms-1.2.4}"
RUNTIME="${MW_RUNTIME:-${TMPDIR:-/tmp}/xforms-wayland-runtime}"
DEMO_SECS="${DEMO_SECS:-4}"
# Run from demos/ so the demos find their .xpm/.xbm data files (XForms looks for
# them in the current directory), with the wrapper scripts in that directory --
# they set the library path for the build tree's own libforms.
DEMOS="$XFORMS_SRC/demos"
FRAMES="${FRAMES:-}"

[ -x "$BUILD/headless-compositor" ] || { echo "build the shim first ($BUILD)" >&2; exit 1; }
[ -d "$DEMOS" ] || { echo "build XForms first (scripts/build-xforms.sh)" >&2; exit 1; }
mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
if [ -n "$FRAMES" ]; then mkdir -p "$FRAMES"; WORK="$FRAMES"; else WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; fi

# The GL demos call GLX, which does not exist on Wayland, so they are built out
# (--disable-gl); everything else in demos/ is fair game.
DEFAULT_DEMOS=(
    arrowbutton boxtype browserall browserop buttonall butttypes canvas
    chartall chartstrip choice colbrowser colsel colsel1 counter cursor
    demo demo05 demo06 demo27 demo33 demotest demotest2 demotest3 dirlist
    fbrowse fbrowse1 fdial flclock folder fonts formbrowser free1 freedraw
    goodies grav group ibrowser iconify inputall invslider lalign ldial ll
    longlabel menu minput minput2 multilabel ndial newbutton new_popup nmenu
    objinactive objpos objreturn pmbrowse popup positioner
    positioner_overlay positionerXOR preemptive pushbutton pushme rescale
    scrollbar secretinput select sld_alt sldinactive sld_radio sldsize
    sliderall strange_button strsize symbols thumbwheel timeoutprec timer
    timerprec touchbutton xyplotactive xyplotactivelog xyplotall xyplotover
    yesno yesno_cb
)

want=("$@")
selected() {
    [ "${#want[@]}" -eq 0 ] && return 0
    local c; for c in "${want[@]}"; do [ "$c" = "$1" ] && return 0; done
    return 1
}

colours() {
    python3 - "$1" 2>/dev/null <<'PY'
import sys
from PIL import Image
try:
    im = Image.open(sys.argv[1]).convert('RGB')
    print(len(set(im.getdata())))
except Exception:
    print("")
PY
}

printf '%-18s %-6s %s\n' DEMO RESULT DETAIL
fail=0; n_ok=0; n_ran=0; n_gap=0; n_crash=0; n_skip=0
for name in "${DEFAULT_DEMOS[@]}"; do
    selected "$name" || continue
    if [ ! -x "$DEMOS/$name" ]; then
        n_skip=$((n_skip+1))
        printf '%-18s %-6s %s\n' "$name" skip "not built"
        continue
    fi

    sock="xfd$$_$name"
    XDG_RUNTIME_DIR="$RUNTIME" "$BUILD/headless-compositor" \
        --socket "$sock" --size 800x600 \
        --timeout "$DEMO_SECS" --output "$WORK/$name.png" \
        >"$WORK/$name.ready" 2>"$WORK/$name.hc" &
    hc=$!
    for _ in $(seq 1 200); do
        grep -q READY "$WORK/$name.ready" 2>/dev/null && break; sleep 0.05
    done
    ( cd "$DEMOS" && XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$sock" \
      LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}" \
      timeout "$DEMO_SECS" "./$name" ) >"$WORK/$name.out" 2>&1
    rc=$?
    wait "$hc" 2>/dev/null

    npix="$(colours "$WORK/$name.png")"
    missing="$(grep -oE 'undefined symbol: [A-Za-z_0-9]+' "$WORK/$name.out" \
               | head -1 | awk '{print $3}')"
    detail=""
    if [ "$rc" -ge 128 ] && [ "$rc" -ne 124 ]; then
        result=crash; n_crash=$((n_crash+1))
        detail="$(grep -m1 -iE 'free\(\)|segmentation|assert|abort' "$WORK/$name.out" | head -c 60)"
        [ -n "$detail" ] || detail="signal $((rc-128))"
    elif [ -n "$missing" ]; then
        result=gap; n_gap=$((n_gap+1)); detail="needs $missing"
    elif [ -n "$npix" ] && [ "$npix" -gt 1 ]; then
        result=ok; n_ok=$((n_ok+1)); detail="painted ($npix colours)"
    else
        result=ran; n_ran=$((n_ran+1))
        detail="no frame"
        grep -q "no mapped surface" "$WORK/$name.hc" && detail="$detail (nothing mapped)"
    fi
    printf '%-18s %-6s %s\n' "$name" "$result" "$detail"

    if [ "$result" = crash ]; then
        fail=1
        sed 's/^/  /' "$WORK/$name.out" | head -5
    elif [ "$result" = ran ] || [ "$result" = gap ]; then
        sed 's/^/  /' "$WORK/$name.out" | head -3
    fi
done

echo
echo "ok=$n_ok ran=$n_ran gap=$n_gap crash=$n_crash skip=$n_skip"
[ -n "$FRAMES" ] && echo "frames and logs: $WORK"
exit "$fail"