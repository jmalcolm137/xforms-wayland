# XForms on Wayland

Run [XForms](http://xforms-toolkit.org/) — unmodified, from the upstream 1.2.4
tarball — natively on Wayland, with no XWayland and no X server.

XForms is a pure-Xlib widget toolkit: a program includes `<forms.h>` and links
`-lforms -lX11`, nothing else. So the whole problem is one layer deep:

```
   your XForms program / the bundled demos        (unmodified)
        |
   libforms.so.2.1.3                              (unmodified upstream source)
        |
   libX11.so.6  ==  xlib-wayland                  (Wayland-native Xlib)
        |
   Wayland
```

[`xlib-wayland`](https://github.com/jmalcolm137/xlib-wayland) is a
Wayland-native, ABI-compatible implementation of `libX11`. Because it installs as
`libX11.so.6`, the stock XForms build links against it with no source changes and
no patching of XForms. Anything XForms turns out to need from Xlib is fixed in
xlib-wayland, not here.

## Status

| Milestone | State |
|---|---|
| XForms 1.2.4 `configure` + `make` + `make install` unmodified against the shim | ✅ done |
| The three examples from [xforms-toolkit.org/examples.html](http://xforms-toolkit.org/examples.html) render **and** handle clicks | ✅ done |
| 86 bundled demos start, map a window and paint on Wayland | ✅ done (85 of 86 paint; the exception is a legitimately empty canvas, see below) |
| Interactive verification under a live session (KDE Plasma) | ✅ done |
| Crisp output on a HiDPI display (render at the output scale) | ✅ done (2× on a scale-2 panel) |
| Missing Xlib symbols | none — see [DESIGN.md §2.1](DESIGN.md) |

Two results worth calling out:

* **No missing symbols.** XForms' `lib/` calls 149 distinct `X*` functions and the
  shim exports 586; the intersection is total. The work is verification and
  integration, not porting.
* **Input works, not just painting.** Each example is driven by a scripted
  pointer sequence replayed by the headless compositor, and the *behaviour* is
  checked: `xftest1` exits 0 when its button is pressed, `xftest2` prints
  `Hello world` and keeps running until `Quit` is pressed, `xftest3` prints from a
  `fl_set_object_callback()` handler, and `xftest4` opens a pulldown menu on a
  borderless (`FL_NOBORDER`, i.e. override-redirect) form and selects an item.
  Getting this to work needed one fix in xlib-wayland: the test compositor started
  an input script on a fixed timer, so a client slower to map than 400 ms silently
  lost every event.
* **HiDPI is handled by rendering, not stretching.** On a scale-2 output the shim
  reports the *logical* screen size and renders every surface at twice the
  resolution, then tells the compositor with `wl_surface.set_buffer_scale`, so
  text and lines are crisp rather than a 1× buffer the compositor blows up. No
  application or XForms code changes; coordinates stay logical throughout. The
  whole demo matrix is run a second time at `HC_SCALE=2` and every frame comes out
  exactly 2× the scale-1 size with the same classification.

## Quick start

Nothing needs root. Everything installs under your home directory.

```sh
export MW_PREFIX="$HOME/.local/motif-wayland"          # the shim
export XFORMS_PREFIX="$HOME/.local/xforms"             # XForms
export XFORMS_SRC="$HOME/src/xforms/xforms-1.2.4"      # unpacked tarball

# 1. the shim (also gives us the headless compositor used for testing)
(cd xlib-wayland && meson setup build --prefix="$MW_PREFIX" && meson install -C build)

# 2. XForms, built from unmodified upstream sources against the shim
scripts/build-xforms.sh --install

# 3. the examples from the XForms examples page (plus xftest4, a local one)
examples/build-examples.sh

# 4. run them, headless and pixel-checked
scripts/run-xforms-examples.sh
scripts/run-xforms-examples.sh xftest1        # or just one
```

### Running a demo by hand

```sh
cd "$XFORMS_SRC/demos"
LD_LIBRARY_PATH="$MW_PREFIX/lib" ./buttonall
```

`DISPLAY` is not used; the shim connects to `$WAYLAND_DISPLAY`.

## Building XForms: the only two accommodations

Both are build flags, not source edits — the same kind of host-compiler
accommodation NEdit needs (`-std=gnu89 -fcommon`) in the xlib-wayland README:

| Flag | Why |
|---|---|
| `-fcommon` | XForms predates C23 and relies on tentative definitions (`int curobj;` appears in both `fdesign/sp_twheel.c` and `sp_spinner.c`), which GCC ≥ 10 rejects by default. Without it `fdesign` fails to link. |
| `-I/usr/include` | The shim installs no headers — there is nothing in the Xlib API it does not implement — so we compile against the system X11 headers, which are ABI-compatible with the shim by construction. |

Plus `--enable-demos` (without it only the library, `fdesign` and `xfd` are built)
and `--disable-gl` (the GL demos call GLX, which has no Wayland equivalent).

## Tests

`scripts/run-xforms-examples.sh` runs each example twice under the bundled
headless compositor: once with no input to check it maps and paints, then once
with a scripted click sequence to check the toolkit's event dispatch. It
classifies each run `ok` / `ran` / `gap` (missing shim symbol) / `crash`
(a shim defect).

`scripts/run-xforms-demos.sh` does the same for the bundled demos — the wider
corpus covering menus and override-redirect popups, Xpm pixmaps, bitmaps, fonts,
text input and XIM, browsers with async I/O, canvas/chart drawing and timers.

```sh
scripts/run-xforms-examples.sh                 # the examples
scripts/run-xforms-demos.sh                    # all bundled demos
scripts/run-xforms-demos.sh menu popup choice  # a subset
FRAMES=/tmp/frames scripts/run-xforms-demos.sh # keep the PNGs and logs
HC_SCALE=2 scripts/run-xforms-demos.sh         # exercise the HiDPI path
```

Both scripts exit non-zero on any crash.

## Known limitations

* **The GL demos are not built.** `gl*` call GLX; on Wayland the equivalent is
  EGL, which is a different API. They are excluded via `--disable-gl` rather than
  left to fail to link.
* **Fifteen demos paint nothing inside the harness window** (`demo05`, `demo06`,
  `demo27`, `demo33`, `free1`, `multilabel`, `objinactive`, `positioner`,
  `pushbutton`, `pushme`, `sld_alt`, `sldinactive`, `sld_radio`, `sldsize`,
  `touchbutton`). They all start and stay up; some ask on stdin before showing a
  window, others open a window larger than the 800×600 canvas the harness
  configures. See [DESIGN.md §7](DESIGN.md) for the per-demo notes.
* **`libXpm` is the system one**, unmodified. It is used through the shim's
  `XCreateImage`/`XPutPixel` path, which works, but bugs in `libXpm` are not ours
  to fix.
* **Pixmaps are still logical-resolution.** Drawing straight into a window is
  rendered at the HiDPI scale and is crisp; a client pixmap copied into a scaled
  window is resampled, so content that lives only in a pixmap is softer. None of
  the demos hit this visibly.
* **Logical DPI is a flat 96**, so on a HiDPI panel text is physically smaller
  than its nominal point size unless the session applies text scaling. Matches the
  usual HiDPI trade-off; see [DESIGN.md §7](DESIGN.md).
* **`run-xforms-examples.sh` is timing-flaky** (about 1 run in 5 loses the first
  scripted click). It is pre-existing and reproduces against the parent revision;
  the shim delivers the events in both cases. See [DESIGN.md §7](DESIGN.md).

## Documentation

[DESIGN.md](DESIGN.md) is the design document: the approach, the measured Xlib
API surface XForms needs, the mapping of XForms concepts onto Wayland, the build
integration, the test strategy and the risk analysis.

## Licence

MIT — see [LICENSE](LICENSE). XForms itself is distributed under its own terms
(GPL with the X11 exception / BSD-style mix as shipped in its tarball) and is
neither modified nor redistributed here.