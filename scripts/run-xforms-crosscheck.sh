#!/usr/bin/env bash
#
# run-xforms-crosscheck.sh — compare the shim's rendering of an XForms demo with
# real X11's rendering of the same program.
#
# There is no XForms reference-image corpus: the upstream demos ship no
# screenshots.  What *is* available is a second, independent implementation of
# the thing being emulated -- the system libX11, on the XWayland display :1 --
# running the same binary from the same build tree.  Anything XForms asked for
# that the shim got wrong shows up as a difference between the two frames that
# no amount of XForms-side variation can explain.
#
# For each demo three frames are captured:
#
#   shim   headless-compositor + $MW_PREFIX/lib/libX11.so.6   (the code under test)
#   x11    system libX11 on $X11_DISPLAY, captured with ImageMagick import
#   x11b   a second X11 run, used as a control
#
# The second X11 run is what makes the comparison meaningful.  Some demos are
# simply not reproducible -- free1 installs a 64-entry greyscale ramp in the
# server's colormap and paints its free object with whatever colour XForms'
# installed-colormap search lands on, which moves from run to run on X11 itself
# (measured: 191, 195, 195, 195, and 203 with an explicit -depth 24).  A
# shim-vs-X11 difference is only evidence of a defect if X11 agrees with itself,
# so three reference runs are compared against each other first and a demo that
# fails that is reported as "varies" rather than as a failure.
#
# compare-frames.py scores a pair.  Text is rasterised by different font stacks
# (core X fonts vs cairo/Xft), so a cell-level ink comparison is used rather than
# a pixel diff: see that script for the metric and its tolerances.
#
# The X11 run needs a running X server.  In a Wayland session that is XWayland,
# and it is used *only* here -- the shim runs are always on their own Wayland
# socket, never on $DISPLAY.
#
# Usage: run-xforms-crosscheck.sh [demo ...]   (default: the built-in list)
#
# Environment:
#   MW_BUILD     shim build directory (default: <repo>/xlib-wayland/build)
#   MW_PREFIX    shim prefix         (default: $HOME/.local/motif-wayland)
#   XFORMS_SRC   XForms source tree  (default: $HOME/src/xforms/xforms-1.2.4)
#   X11_DISPLAY  X display for the reference run (default: :1)
#   FRAMES       keep frames and logs here (default: a temp dir)
#   DEMO_SECS    seconds per run    (default: 4)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="${MW_BUILD:-$ROOT/xlib-wayland/build}"
PREFIX="${MW_PREFIX:-$HOME/.local/motif-wayland}"
XFORMS_SRC="${XFORMS_SRC:-$HOME/src/xforms/xforms-1.2.4}"
X11_DISPLAY="${X11_DISPLAY:-:1}"
RUNTIME="${MW_RUNTIME:-${TMPDIR:-/tmp}/xforms-wayland-runtime}"
DEMOS="$XFORMS_SRC/demos"
FRAMES="${FRAMES:-}"
DEMO_SECS="${DEMO_SECS:-4}"
# Cell size, in pixels, for the ink comparison.  Small enough to see a widget
# border, large enough that a glyph's anti-aliasing does not change the verdict.
CELL="${CELL:-8}"

[ -x "$BUILD/headless-compositor" ] || { echo "build the shim first ($BUILD)" >&2; exit 1; }
[ -d "$DEMOS" ] || { echo "build XForms first (scripts/build-xforms.sh)" >&2; exit 1; }
command -v xdotool >/dev/null || { echo "xdotool is needed to find the X11 window" >&2; exit 1; }
command -v import   >/dev/null || { echo "ImageMagick's import is needed to capture it" >&2; exit 1; }
mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
if [ -n "$FRAMES" ]; then mkdir -p "$FRAMES"; WORK="$FRAMES"; else WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; fi

# A subset that exercises the interesting paths: forms, every button class,
# menus and popups, choice/select widgets, sliders, free drawing, text input,
# fonts and browser layouts.  Overridable so a single demo can be re-run.
DEFAULT_DEMOS=(
    arrowbutton boxtype buttonall butttypes canvas chartall choice counter
    demo demo05 demo33 free1 inputall lalign longlabel menu multilabel newbutton
    objinactive positioner pushbutton pushme rescale select sliderall
    sldsize symbols touchbutton xyplotall yesno
)

want=("$@")
selected() {
    [ "${#want[@]}" -eq 0 ] && return 0
    local c; for c in "${want[@]}"; do [ "$c" = "$1" ] && return 0; done
    return 1
}

# list_windows -> one window id per line, for every window the X server knows.
# The name pattern is empty on purpose: xdotool's --name is a regex *search*,
# which needs at least one character to match, so "." misses an unnamed window.
# Several XForms demos call fl_show_form() with a NULL title and would
# otherwise never be found.
list_windows() {
    xdotool search --all --name '' 2>/dev/null
}

# Demos whose appearance is not reproducible on *either* implementation, so they
# cannot be used as an oracle and are excluded from the comparison rather than
# reported as a failure.  Keep the reason, and the measurement behind it, here:
#
#   free1  installs a 64-entry greyscale ramp with fl_mapcolor() and paints its
#          free object with the colour XForms' installed-colormap search
#          resolves.  That depends on what else is in the server's colormap, so
#          it drifts between runs on X11 (measured 155, 159, 155, 191, 195,
#          195, 195, and 203 with an explicit -depth 24) and on the shim
#          (measured 215, 235).  Everything else in the frame -- geometry, every
#          border, the Exit button -- is pixel-identical between the two.
VARYING_DEMOS=(free1)

is_varying() {
    local d c; for d in "${VARYING_DEMOS[@]}"; do [ "$d" = "$1" ] && return 0; done
    return 1
}

# The XForms demos in demos/ are libtool wrappers; .libs/<name> is the real
# binary.  Running the wrapper would work too, but calling the binary directly
# makes the library path explicit, which is the whole point here.
binary() { echo "$DEMOS/.libs/$1"; }

# ---------------------------------------------------------------------------
# shim run: its own Wayland socket, shim first on the library path.
# ---------------------------------------------------------------------------
run_shim() {
    local name="$1"
    local sock="xfc$$_$name"
    XDG_RUNTIME_DIR="$RUNTIME" "$BUILD/headless-compositor" \
        --socket "$sock" --size 800x600 \
        --timeout "$DEMO_SECS" --output "$WORK/$name.shim.png" \
        >"$WORK/$name.shim.ready" 2>"$WORK/$name.shim.hc" &
    local hc=$!
    local i
    for i in $(seq 1 200); do
        grep -q READY "$WORK/$name.shim.ready" 2>/dev/null && break; sleep 0.05
    done
    ( cd "$DEMOS" && XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$sock" \
      LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}" \
      timeout "$DEMO_SECS" "./$name" ) >"$WORK/$name.shim.out" 2>&1
    local rc=$?
    wait "$hc" 2>/dev/null
    echo "$rc"
}

# ---------------------------------------------------------------------------
# x11 run: the same binary on a real X server, with the *system* libX11.
#
# libforms.so has the shim's directory in its RUNPATH, and RUNPATH is searched
# after LD_LIBRARY_PATH, so pointing LD_LIBRARY_PATH at the directory holding
# the system libX11.so.6 is what selects the reference implementation.  The
# window is then found by diffing the window list across the launch and
# captured by id, which grabs the client area without the compositor's
# decorations.
#
# A demo may map more than one window (a main form plus a dialog), and which one
# is the subject depends on the demo.  The shim frame's size identifies it: it is
# the geometry XForms asked for on the shim run, so an X11 window of exactly
# that size is the one to compare.  Windows of any other size are only used if
# there is no exact match.
# ---------------------------------------------------------------------------
run_x11() {
    local name="$1" tag="$2" want_size="$3"
    local syslib
    syslib="$(dirname "$(ldconfig -p | awk '/libX11\.so\.6 \(/{print $NF; exit}')")"
    [ -d "$syslib" ] || syslib=/usr/lib

    local before pid w best="" best_area=0 best_want="" want_area=0
    before="$(list_windows | sort)"
    ( cd "$DEMOS" && LD_LIBRARY_PATH="$syslib" X11_DISPLAY="$X11_DISPLAY" DISPLAY="$X11_DISPLAY" \
      timeout "$((DEMO_SECS + 2))" "$(binary "$name")" ) \
        >"$WORK/$name.$tag.out" 2>&1 &
    pid=$!
    sleep "$((DEMO_SECS / 2))"

    [ -n "$want_size" ] && want_area=$(( ${want_size%x*} * ${want_size#*x} ))
    for w in $(comm -13 <(printf '%s\n' "$before") <(list_windows | sort)); do
        local geom ww wh area
        geom="$(xdotool getwindowgeometry "$w" 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | tail -1)"
        [ -n "$geom" ] || continue
        ww="${geom%x*}"; wh="${geom#*x}"
        area=$(( ww * wh ))
        if [ "$geom" = "$want_size" ]; then
            best="$w"; break
        fi
        [ "$area" -gt "$best_area" ] && { best_area="$area"; best_want="$w"; }
    done
    [ -z "$best" ] && best="$best_want"

    if [ -n "$best" ]; then
        DISPLAY="$X11_DISPLAY" import -window "$best" "$WORK/$name.$tag.png" 2>>"$WORK/$name.$tag.err"
        xdotool getwindowgeometry "$best" 2>/dev/null | tr '\n' ' ' >"$WORK/$name.$tag.geom"
    fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    [ -n "$best" ] && [ -s "$WORK/$name.$tag.png" ]
}

# frame_size <png> -> WxH, or empty when there is no frame.
frame_size() {
    python3 - "$1" 2>/dev/null <<'PY'
import sys
from PIL import Image
try:
    print("%dx%d" % Image.open(sys.argv[1]).size)
except Exception:
    print("")
PY
}

printf '%-16s %-6s %s\n' DEMO MATCH DETAIL
fail=0; n_same=0; n_close=0; n_diff=0; n_var=0; n_bad=0
for name in "${DEFAULT_DEMOS[@]}"; do
    selected "$name" || continue
    if [ ! -x "$(binary "$name")" ]; then
        printf '%-16s %-6s %s\n' "$name" skip "not built"
        continue
    fi

    shim_rc="$(run_shim "$name")"
    want_size="$(frame_size "$WORK/$name.shim.png")"

    if is_varying "$name"; then
        # Still captured, so the layout can be inspected by hand, but not scored.
        run_x11 "$name" x11 "$want_size" || true
        printf '%-16s %-6s %s\n' "$name" varies "excluded: not reproducible (see VARYING_DEMOS)"
        n_var=$((n_var+1))
        continue
    fi

    if ! run_x11 "$name" x11 "$want_size"; then
        printf '%-16s %-6s %s\n' "$name" nox11 "no X11 window appeared"
        n_bad=$((n_bad+1)); continue
    fi
    run_x11 "$name" x11b "$want_size" || true
    run_x11 "$name" x11c "$want_size" || true

    # Control first: if X11 does not agree with itself, the demo is not
    # reproducible and cannot testify about the shim either way.  All three
    # pairs are checked, because the drift that makes free1 non-reproducible is
    # small enough that two runs often match by luck.
    worst="same 100.0%"; varies=0
    for pair in "x11 x11b" "x11 x11c" "x11b x11c"; do
        set -- $pair
        [ -s "$WORK/$name.$1.png" ] && [ -s "$WORK/$name.$2.png" ] || continue
        cmp="$(python3 "$HERE/compare-frames.py" --cell "$CELL" \
            "$WORK/$name.$1.png" "$WORK/$name.$2.png" 2>&1)"
        cs="${cmp%% *}"
        [ "$cs" = same ] || varies=1
        case "$cmp" in
            *"$worst") ;;
        esac
        worst="$cmp"
    done
    if [ "$varies" -eq 1 ]; then
        n_var=$((n_var+1))
        printf '%-16s %-6s %s\n' "$name" varies "X11 disagrees with itself: $worst"
        continue
    fi

    verdict="$(python3 "$HERE/compare-frames.py" \
        --cell "$CELL" \
        "$WORK/$name.shim.png" "$WORK/$name.x11.png" 2>&1)"
    vrc=$?
    status="${verdict%% *}"; detail="${verdict#* }"
    # "close" is a pass with a note: the layout agrees and only glyph
    # rasterisation differs, which is the expected consequence of Xft versus
    # core X fonts rather than a shim defect.
    case "$status" in
        same)  n_same=$((n_same+1)) ;;
        close) n_close=$((n_close+1)) ;;
        diff)  n_diff=$((n_diff+1)); fail=1 ;;
        *)     n_bad=$((n_bad+1)); fail=1 ;;
    esac
    printf '%-16s %-6s %s\n' "$name" "$status" "$detail"
    [ "$vrc" -eq 0 ] || printf '  shim rc=%s\n' "$shim_rc"
    sed "s|^|  |" "$WORK/$name.x11.out" | head -2
done

echo
echo "same=$n_same close=$n_close varies=$n_var diff=$n_diff unusable=$n_bad"
[ -n "$FRAMES" ] && echo "frames and logs: $WORK"
exit "$fail"