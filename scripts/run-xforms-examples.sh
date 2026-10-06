#!/usr/bin/env bash
#
# run-xforms-examples.sh — run XForms programs against the xlib-wayland shim.
#
# The same idea as the parent's run-x11-clients.sh, applied to XForms: there is no
# XForms conformance suite, so the substitute is to build the real thing from
# unmodified upstream source and run it.  Each program runs under the bundled
# headless compositor with the shim first on the library path.
#
# Every program is run twice:
#
#   paint   no input, just long enough to map and draw.  The captured frame must
#           contain more than one colour, i.e. something was actually rendered.
#   drive   a scripted pointer/keyboard sequence replayed by the compositor
#           (examples/inputs/*.input).  The program's *behaviour* is then checked:
#           xftest1 exits 0 when its single button is pressed, xftest2 exits 0
#           only when "Quit" is pressed (and prints "Hello world" when the other
#           one is), xftest3 prints "Hello world" from the callback without
#           exiting.  This is what distinguishes "it drew a window" from "the
#           toolkit's event dispatch works".
#
# Each run is classified:
#
#   ok      painted and behaved as expected
#   ran     started and exited without a missing symbol, but failed a check
#   gap     needs an Xlib symbol the shim does not export
#   crash   died on a signal -- a shim defect, never acceptable
#
# Usage: run-xforms-examples.sh [program ...]
#        (default: the three examples from http://xforms-toolkit.org/examples.html)
#
# Environment:
#   MW_BUILD     shim build directory (default: <repo>/xlib-wayland/build)
#   MW_PREFIX    shim prefix         (default: $HOME/.local/motif-wayland)
#   XFORMS_SRC   XForms source tree  (default: $HOME/src/xforms/xforms-1.2.4)
#   MW_RUNTIME   compositor runtime  (default: ${TMPDIR:-/tmp}/xforms-wayland-runtime)
#   FRAMES       keep frames and logs in this directory (default: a temp dir)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="${MW_BUILD:-$ROOT/xlib-wayland/build}"
PREFIX="${MW_PREFIX:-$HOME/.local/motif-wayland}"
XFORMS_SRC="${XFORMS_SRC:-$HOME/src/xforms/xforms-1.2.4}"
RUNTIME="${MW_RUNTIME:-${TMPDIR:-/tmp}/xforms-wayland-runtime}"
EXAMPLES_DIR="$ROOT/examples"
FRAMES="${FRAMES:-}"
# The screenshot must be taken while the client is still alive, so the
# compositor's deadline is the shorter of the two.  Afterwards the client sees
# the connection close and exits with Xlib's "Wayland connection closed" message,
# which is the expected way for a still-running interactive program to end here.
COMPOSITOR_TIMEOUT=6
CLIENT_TIMEOUT=8

[ -x "$BUILD/headless-compositor" ] || { echo "build the shim first ($BUILD)"; exit 1; }
[ -e "$XFORMS_SRC/lib/.libs/libforms.so" ] || {
    echo "build XForms first (scripts/build-xforms.sh)" >&2; exit 1; }
mkdir -p "$RUNTIME"; chmod 700 "$RUNTIME"
if [ -n "$FRAMES" ]; then mkdir -p "$FRAMES"; WORK="$FRAMES"; else WORK="$(mktemp -d)"; fi
[ -n "$FRAMES" ] || trap 'rm -rf "$WORK"' EXIT

# name|script|expect-exit|expect-stdout-regex
# An empty script means "no input, just paint".  expect-exit is the exit status the
# drive run must reach (124 = still running, i.e. deliberately not exiting).
PROGRAMS=(
    "xftest1|xftest1.input|0|"
    "xftest2|xftest2.input|0|^Hello world$"
    "xftest3|xftest3.input|0|^Hello world$"
)

want=("$@")
selected() {
    [ "${#want[@]}" -eq 0 ] && return 0
    local c; for c in "${want[@]}"; do [ "$c" = "$1" ] && return 0; done
    return 1
}

colours() { # png -> number of distinct colours (empty when there is no frame)
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

# run_client <name> <phase> [input-file] -> sets rc, prints nothing
run_client() {
    local name="$1" phase="$2" input="${3:-}"
    local sock="xfw$$_${name}_${phase}"
    local args=(--socket "$sock" --size 640x400
                --timeout "$COMPOSITOR_TIMEOUT" --output "$WORK/$name.$phase.png")
    [ -n "$input" ] && args+=(--input "$input")
    XDG_RUNTIME_DIR="$RUNTIME" "$BUILD/headless-compositor" "${args[@]}" \
        >"$WORK/$name.$phase.ready" 2>"$WORK/$name.$phase.hc" &
    hc=$!
    local i
    for i in $(seq 1 200); do
        grep -q READY "$WORK/$name.$phase.ready" 2>/dev/null && break; sleep 0.05
    done
    # shellcheck disable=SC2086
    ( XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$sock" \
      LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}" \
      timeout "$CLIENT_TIMEOUT" "$EXAMPLES_DIR/$name" ) \
        >"$WORK/$name.$phase.out" 2>&1
    rc=$?
    wait "$hc" 2>/dev/null
}

printf '%-10s %-6s %s\n' PROGRAM RESULT DETAIL
fail=0
for entry in "${PROGRAMS[@]}"; do
    IFS='|' read -r name script want_rc want_out <<<"$entry"
    selected "$name" || continue
    prog="$EXAMPLES_DIR/$name"
    if [ ! -x "$prog" ]; then
        printf '%-10s %-6s %s\n' "$name" skip "not built (examples/build-examples.sh)"
        continue
    fi

    detail=""
    # --- phase 1: does it map and paint? ---
    run_client "$name" paint
    npix="$(colours "$WORK/$name.paint.png")"
    missing="$(grep -oE 'undefined symbol: [A-Za-z_0-9]+' "$WORK/$name.paint.out" \
               | head -1 | awk '{print $3}')"
    if [ "$rc" -ge 128 ] && [ "$rc" -ne 124 ]; then
        result=crash
        detail="$(grep -m1 -iE 'free\(\)|segmentation|assert|abort' "$WORK/$name.paint.out" | head -c 60)"
        [ -n "$detail" ] || detail="signal $((rc-128))"
    elif [ -n "$missing" ]; then
        result=gap; detail="needs $missing"
    elif [ -z "$npix" ] || [ "$npix" -le 1 ]; then
        result=ran
        detail="no frame painted"
        grep -q "no mapped surface" "$WORK/$name.paint.hc" && detail="$detail (nothing was mapped)"
    else
        # --- phase 2: does the toolkit dispatch input? ---
        run_client "$name" drive "$EXAMPLES_DIR/inputs/$script"
        if [ "$rc" -ge 128 ] && [ "$rc" -ne 124 ]; then
            result=crash
            detail="crashed on scripted input (signal $((rc-128)))"
        elif [ -n "$want_rc" ] && [ "$rc" -ne "$want_rc" ]; then
            result=ran
            detail="painted ($npix colours) but drive run exited $rc, wanted $want_rc"
        elif [ -n "$want_out" ] && ! grep -qE "$want_out" "$WORK/$name.drive.out"; then
            result=ran
            detail="painted ($npix colours) but stdout missing /$want_out/"
        else
            result=ok
            detail="painted $npix colours; scripted click handled, exit $rc"
            [ -n "$want_out" ] && detail="$detail; stdout /$want_out/ seen"
        fi
    fi
    printf '%-10s %-6s %s\n' "$name" "$result" "$detail"

    [ "$result" = crash ] && fail=1
    if [ "$result" != ok ]; then
        echo "  --- $name.paint.out"; sed 's/^/  /' "$WORK/$name.paint.out" 2>/dev/null | head -5
        [ -s "$WORK/$name.drive.out" ] && { echo "  --- $name.drive.out"; sed 's/^/  /' "$WORK/$name.drive.out" | head -5; }
    fi
done

[ -n "$FRAMES" ] && echo "frames and logs: $WORK"
exit "$fail"