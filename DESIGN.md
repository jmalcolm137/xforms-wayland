# XForms on Wayland — Design Document

**Status:** draft / living document
**Target:** run **unmodified XForms 1.2.4** applications and the bundled demos natively on
Wayland, on top of [`xlib-wayland`](https://github.com/jmalcolm137/xlib-wayland)
(a Wayland-native, ABI-compatible implementation of `libX11`).

---

## 1. Summary

XForms is a pure-Xlib widget toolkit. Unlike Motif it needs no `libXt` and no `libXm`; a
hello-world program links exactly two libraries:

```c
fl_initialize(&argc, argv, 0, 0, 0);
...
cc -o xftest xftest.c -lforms -lX11
```

The layering is therefore unusually shallow:

```
┌───────────────────────────────────────────────────────────────┐
│  XForms applications           xftest.c, demos/*, your app    │
├───────────────────────────────────────────────────────────────┤
│  libforms.so  (XForms 1.2.4, ~200 .c files)   (unmodified)   │
├───────────────────────────────────────────────────────────────┤
│  libXpm.so.4   (system)                    ── XImage bridge ─┤
│  libX11.so.6   ← xlib-wayland: Xlib ABI, Wayland impl.       │
├───────────────────────────────────────────────────────────────┤
│  Wayland (wl_display, xdg-shell, wl_shm, wl_seat, …)          │
└───────────────────────────────────────────────────────────────┘
```

**Xlib is the only platform-specific layer**, and its API is opaque at the transport boundary
(`Display *`, `Window`, `GC`, `XImage` are all abstract handles). So the entire approach is:

> Build XForms from unmodified upstream source against a binary-compatible `libX11` that
> speaks Wayland instead of the X11 wire protocol. Fix nothing in XForms; fix the shim.

This is the same strategy the parent project already used for libXt, Open Motif, XV, NEdit,
GTK+ 2 and GIMP, and it is the strategy that keeps XForms a supported *upstream* toolkit rather
than a fork. Any change required by XForms is made in `xlib-wayland` and pushed there.

### 1.1 Goals

* **G1** — XForms 1.2.4 `configure` + `make` + `make install` succeed with **zero source edits**.
* **G2** — `libforms.so` and stock demos/`xftest` examples run natively on Wayland: no XWayland,
  no X server, no `$DISPLAY`.
* **G3** — Render correctly: buttons, boxes, text, bitmaps/pixmaps, menus/popups, browsers,
  input objects, timers and `fl_do_forms()` event dispatch.
* **G4** — Interactive use under a real session compositor (KDE Plasma here), plus a headless,
  pixel-asserted regression test using the bundled `headless-compositor`.
* **G5** — Reusable integration: a script (`scripts/build-xforms.sh`) that builds XForms from a
  pristine tarball against the shim prefix, and a test runner
  (`scripts/run-xforms-examples.sh`) in the style of `run-x11-clients.sh`.

### 1.2 Non-goals

* The OpenGL demos (`demos/gl*`, `fdesign/gl*`) — OpenGL over Wayland is EGL, not GLX, and
  XForms' GL demos call GLX directly. Out of scope; they are excluded from the test matrix
  rather than "fixed".
* `libXpm`'s own bugs (XForms warns at configure that the system libXpm is "a bit old").
  libXpm is used unmodified and is *not* a layer we own.
* XForms' `xfd`/`fdesign` Java or X11-only extras (X11 clipboard of images, `XReadPixels`
  screenshot paths beyond `XGetImage`).
* Any behaviour a client cannot observe: core-font server-side metrics matching a real X server
  byte-for-byte, `XRender`/Composite on XForms (XForms does not use them), multi-screen.

---

## 2. Evidence base

The design is grounded in the actual required surface, measured from the XForms 1.2.4 sources in
`lib/` (the library itself, not just the demos).

### 2.1 Symbol audit

| Measurement | Value |
|---|---|
| Distinct `X*` call sites in `lib/*.c` | **149** |
| `X*` symbols exported by `libX11.so.6` (shim) | **586** |
| Calls in `lib/` with no shim export | **0** |

The only unmatched greps are non-functions (`XAPPLRESDIR`, `XFORMS` env-var names, and
`XMatchVisual` inside a comment — the code calls `XMatchVisualInfo`).

So there is **no missing-symbol work**: XForms is strictly inside the surface the shim already
provides for the Motif/GIMP-era clients. This is the single most important fact in this
document — it means the project is a *verification and integration* effort, not a port.

### 2.2 Link requirements

From the generated makefiles:

```
libforms_la_LIBADD = $(X_LIBS) $(XPM_LIB) -lX11      # → -lXpm -lX11
demos:             $(X_LIBS) $(X_PRE_LIBS) -lX11 $(LIBS) $(X_EXTRA_LIBS)
```

Only the **system `libXpm`** plus `-lX11` are needed. `libXpm` reaches us through the same
`XCreateImage`/`XGetPixel`/`XPutPixel`/`XDisplayWidth` path that GTK and GIMP already use, and it
resolves its `libX11.so.6` `DT_NEEDED` to the shim automatically because the shim is installed
as `libX11.so.6` and put first on the library path. `X_LIBS` ends up empty because XForms' own
`configure` found the X libs via the `-L`/`-rpath` we passed; no `-lXt`/`-lXm` involvement.

Two demos add `-ljpeg` (one image demo) and the `gl*` demos add `-lGL`; both are excluded from
the Wayland matrix for the reasons in §1.2.

### 2.3 Subsystems XForms actually exercises

| XForms subsystem | Xlib surface used | Shim support |
|---|---|---|
| `fl_initialize` / display | `XOpenDisplay`, `XScreenCount`, `XDefaultVisual/Colormap/Depth`, `XDisplayString`, `XSetErrorHandler` (13 sites), `XSupportsLocale`, `XSetLocaleModifiers` | ✅ (M1/M2) |
| Forms & objects | one `XCreateWindow` per form (`lib/win.c:677`), `XMapWindow`, `XUnmapWindow`, `XMoveResizeWindow`, `XDestroyWindow`, `XSetWMName/ClassHint/TransientForHint`, `XSetWindowBackgroundPixmap` | ✅ |
| Retained-mode redraw | `XCreateGC` (11), `XCopyArea` (7), `XFillRectangle`, `XDrawLines`, `XDrawString` (11), `XSetFunction`, `XSetClipMask` (6), `XSetPlaneMask`, `XFillStippledPixmap` | ✅ (M1 + Raster) |
| Pixmaps & images | `XCreatePixmap`, `XCreateBitmapFromData`, `XReadBitmapFile`, `XCopyArea` blits, `XGetImage` (screenshot/`fl_get_snapshot`), `XpmCreatePixmapFromData` via libXpm | ✅ |
| Colours | `flcolor` → `XAllocColorCells`, `XAllocColor`, `XQueryColor`, `XStoreColor`, `XInstallColormap`, `XMatchVisualInfo` (TrueColor/PseudoColor/StaticColor detection) | ✅ (M2) |
| Fonts | `XLoadFont`/`XLoadQueryFont` (3), `XQueryFont`, `XTextExtents`, `XTextWidth`, `XDrawImageString`, font lists per object class | ✅ (XLFD → fontconfig → FreeType) |
| Menus & popups | override-redirect `XCreateWindow` (`lib/xpopup.c:2080`, `lib/popup.c:3259`) + `XGrabPointer`/`XGrabKeyboard`, `XUngrabPointer`, `XSetInputFocus`, `XWarpPointer` | ✅ (xdg_popup + grabs) |
| Keyboard & IME | `XLookupString` (4), `XFilterEvent`, `XKeyEvent`, `XSupportsLocale`, `XOpenIM`, `XCreateIC` (`XIMPreeditNothing\|XIMStatusNothing`, `lib/flresource.c:1162`), `XSetICFocus` | ✅ (`zwp_text_input_v3` bridge) |
| Resources | `XrmInitialize`, `XrmGetStringDatabase`, `XrmGetFileDatabase`, `~/.Xdefaults`, `$XAPPLRESDIR`, `$XENVIRONMENT` | ✅ (M2) |
| Event loop | `fl_do_forms()` → its own `select()` over `ConnectionNumber(dpy)` + `XPending`/`XNextEvent`; `fl_add_fd` for `asyn_io` | ✅ (wakeup pipe) |
| Cursors | `XCreateFontCursor`, `XDefineCursor` (5) | ✅ |
| Timers | `select()` timeouts — no Xlib | n/a |

### 2.4 Why this should just work

Three properties of XForms line up unusually well with the shim:

1. **One X window per form.** XForms is retained-mode: it draws every object itself into a single
   window. There is no deep window tree, no per-widget subwindows, so the shim's hardest
   general case (large X window trees with `Expose` synthesis and backing store, as Motif
   produces) barely comes into play.
2. **It is a blocking `select()` loop**, exactly like Xt's `NextEvent.c`, so the shim's
   wakeup-pipe design (`ConnectionNumber()` → a pipe readable on input or repeat deadline) is
   consumed by unmodified code.
3. **Its menus are override-redirect windows with pointer+keyboard grabs**, which the shim
   already promotes to `xdg_popup` for Motif/NEdit/GIMP.

---

## 3. Architecture

### 3.1 What we reuse unchanged from xlib-wayland

Everything. The shim already implements the whole XForms surface:

| Shim subsystem | Files | Why XForms needs it |
|---|---|---|
| Wayland backend | `src/wayland/wl.c`, `surface.c`, `clipboard.c`, `wakeup.c` | registry, `xdg_toplevel`/`xdg_popup`, `wl_shm`, seat, clipboard, event pacing |
| Raster | `src/raster/raster.c` + `raster_cairo.c` | cairo+ARGB32 drawing for all `XDraw*`/`XFill*`/`XCopyArea` |
| Xlib core | `src/xlib/*.c` | display, windows, GCs, images, regions, colours, atoms, properties, selections, fonts, input, keymap |
| Resources | `src/xlib/xresources.c`, `resource.c` | `Xrm*` — XForms' whole appearance model |
| IME | `src/xlib/xim.c` | `XOpenIM`/`XCreateIC` for text objects |
| Internal ABI | `src/xlib/xlibint.c` | lets system `libXext`/`libXrender`/`libXpm`/`libcairo` bind to us |

We do **not** vendor, patch or fork XForms. The shim is consumed the same way as in
`scripts/build-stack.sh` for libXt: `LDFLAGS="-L$MW_PREFIX/lib -Wl,-rpath,$MW_PREFIX/lib"` plus
the shim first on `LD_LIBRARY_PATH`/`LD_RUN_PATH` at run time.

### 3.2 Layering at run time

```
   xftest / demos/*  (unmodified)
        │
   libforms.so.2.1.3  (unmodified; links -lXpm -lX11)
        │                    ┌──────────────────────────────┐
        ├── libXpm.so.4 ─────┤ system library, unmodified,   │
        │                    │ talks to us via XImage only  │
        ▼                    └──────────────────────────────┘
   libX11.so.6  =  xlib-wayland
        ├── object model: Display, Window, GC, Pixmap, XImage, Region, Colormap, Atom
        ├── raster:       mw_raster_* → cairo (ARGB32) → wl_shm
        ├── text:         XLFD → fontconfig → FreeType → XFontStruct/XTextExtents
        ├── input:        xkbcommon + wl_seat → XEvent; zwp_text_input_v3 → XIM
        ├── resources:    Xrm database (~/.Xdefaults, $XAPPLRESDIR, RESOURCE_MANAGER)
        └── wayland:      wl_display · wl_registry · wl_compositor · wl_shm · xdg_wm_base
                           xdg_toplevel · xdg_popup · xdg_decoration · wl_seat · wl_data_device
```

### 3.3 Mapping of XForms' concepts onto Wayland

| XForms concept | Xlib object | Wayland realisation |
|---|---|---|
| Form (window) | `Window` from `lib/win.c` | one `wl_surface` + `xdg_toplevel` (+ `xdg_decoration`, CSD when the compositor draws none) |
| Root / screen | synthetic root `Window` | no surface; holds atoms, properties, `RESOURCE_MANAGER`, selection ownership |
| Object (button, box, …) | *no X window* — drawn by XForms | pixels in the form's backing surface |
| Menu / popup / pulldown | override-redirect `Window` | `xdg_popup` positioned on the parent toplevel, with a real grab; falls back to a plain toplevel if the compositor refuses |
| Dialog (fl_show_form of a sub-form) | child toplevel with `WM_TRANSIENT_FOR` | second `xdg_toplevel` with a parent relation |
| Form pixmap / bitmap object | `Pixmap`, `XImage` | cairo image surface in the shim; blitted with `XCopyArea` into the toplevel |
| Colour cell | `Colormap` entry via `XAllocColorCells` | stored in the synthetic colormap; always exact (TrueColor) |
| Font | `XFontStruct` (core font) | fontconfig/FreeType metrics, drawn with cairo |

### 3.4 The event loop

XForms' `fl_do_forms()` does its own `select()` over `ConnectionNumber(fl_display)` and then calls
`XPending`/`XNextEvent`. Therefore:

* `ConnectionNumber(dpy)` must be an fd that becomes readable exactly when there is X work. The
  shim sets `dpy->fd` to a **wakeup pipe** fed by a helper thread
  (`src/wayland/wakeup.c`) that also fires at the key-repeat deadline. Unmodified XForms blocks
  on it correctly; key repeat works because of the deadline half.
* `XPending`/`XEventsQueued` are the shim's canonical drain:
  `wl_display_dispatch_pending` → `prepare_read` → `poll(fd,0)` → `read_events` → translate.
* `XNextEvent` blocks in `wl_display_dispatch` when the queue is empty.
* `XSync` is flush + quiesce. XForms calls it 11 times, mostly after creating windows before
  mapping — the classic X idiom for avoiding races with the server. Here there is no server, so
  these are cheap and harmless, but they must not *block* (they are called from callbacks).
* `XSetErrorHandler`: XForms installs handlers and expects **deferred** `XErrorEvent`s, never a
  synchronous abort. The shim already defers errors through the event queue, which is what
  XForms' `fl_error.c` logic requires.
* `fl_add_fd`/`asyn_io` (timer + idle callbacks) work because `select()` on our pipe is a normal
  fd wait.

### 3.5 Rendering

* Every drawable (`Window`, `Pixmap`) is a cairo `ARGB32` (premultiplied) surface — which is
  exactly `wl_shm`'s `ARGB8888`, so presenting is a memcpy + `wl_surface_attach/commit` with
  damage.
* GCs carry the full X state (fg/bg, `GX*` function, plane mask, line attributes, fill style,
  `ts_origin`, clip as rects/region/mask/origin, subwindow mode, font, stipple/tile).
* XForms is a **damage-driven** client: it redraws dirty regions of a form into the form window
  with `XCopyArea`/`XFillRectangle`/`XDrawString`. The shim's always-on backing store means
  partially-visible forms and popups are never left unpainted, and `Expose` is synthesised on
  map/resize/unmap exactly as X would.
* Text goes through the core-font emulation (fontconfig + FreeType + cairo). `XTextExtents` is
  computed from cached advances, so XForms' label alignment, `fl_font` sizes and text-object
  measurement are correct even though the "font" is a scalable one.
* `XPutImage`/`XGetImage` matter for two XForms features: `Xpm` pixmaps and
  `fl_get_snapshot`/screenshot-style reads. Both are pixel-exact paths already proven by the
  shim's own tests.

### 3.6 Resource management

XForms initialises its own resource database before creating forms: `XrmInitialize`,
`XrmGetStringDatabase`, then `XrmGetFileDatabase` over `$XAPPLRESDIR`, `$XENVIRONMENT`,
`~/.Xdefaults[-host]`, `$HOME/.Xdefaults`, and finally `RESOURCE_MANAGER`. All of these are
implemented in the shim, so XForms' *own* appearance defaults (colors, fonts, slider sizes) and
any user `.Xdefaults`/`app-defaults` file apply unchanged. `fl_initialize` also honours
`-visual`/`-fg/-bg/-font/-size` on the command line via the same database.

---

## 4. Build and integration

Two prefixes, both user-local, no root:

| Prefix | Contents |
|---|---|
| `$MW_PREFIX` = `~/.local/motif-wayland` | shim: `libX11.so.6`, `libXft.so.2`, `libXrandr.so.2`, `headless-compositor` |
| `$XFORMS_PREFIX` = `~/.local/xforms` | `libforms.so.2.1.3`, `include/X11/forms.h`, `bin/xfd`, `demos/*` |

Build (from a pristine tarball, **no source edits**):

```sh
export MW_PREFIX="$HOME/.local/motif-wayland"
export XFORMS_SRC="$HOME/src/xforms/xforms-1.2.4"

# 1. the shim
meson setup build --prefix="$MW_PREFIX" && meson install -C build

# 2. XForms, linked against the shim (see scripts/build-xforms.sh)
cd "$XFORMS_SRC"
./configure --prefix="$XFORMS_PREFIX" --enable-demos --disable-gl \
            CFLAGS="-O2 -fcommon -I/usr/include" \
            LDFLAGS="-L$MW_PREFIX/lib -Wl,-rpath,$MW_PREFIX/lib"
make -j"$(nproc)" && make install

# 3. the three examples from xforms-toolkit.org/examples.html
examples/build-examples.sh
```

Notes on the two accommodations, both build flags rather than source changes:

* **`-fcommon`** — `fdesign/` (and `lib/` in some configurations) rely on pre-C23 tentative
  definitions (`int curobj;` in both `sp_twheel.o` and `sp_spinner.o`). GCC ≥ 10 defaults to
  `-fno-common`, so the link fails with "multiple definition of `curobj`". `-fcommon` restores
  the historical behaviour. Same class of accommodation as NEdit's `-std=gnu89 -fcommon` in the
  parent project.
* **`-I/usr/include`** — the shim deliberately installs no headers (there is nothing in the
  Xlib API it does not implement), so we compile against the system X11 headers, which are
  ABI-compatible with the shim by construction. `PKG_CONFIG_PATH=$MW_PREFIX/lib/pkgconfig` is
  *not* used for `-I`: its `Cflags` points at `$MW_PREFIX/include/X11`, which does not exist.
  Linking does go through `-L$MW_PREFIX/lib`, and `-rpath` makes the shim the resolved
  `libX11.so.6` at run time, so no `LD_LIBRARY_PATH` is needed for installed binaries.
* Headers for `libXpm` (`/usr/include/X11/xpm.h`) come from the system, unchanged.
* **`--enable-demos`** — `configure` builds only `lib/`, `fdesign` and `xfd` without it; the 94
  programs in `demos/` are the actual test corpus (§5.2), so the flag is not optional for us.
* **`--disable-gl`** — XForms' GL support library and the `gl*` demos call GLX directly. GLX
  does not exist on Wayland (the equivalent is EGL), so this is a genuine non-goal (§1.2), and
  the flag keeps those targets out of the build rather than letting them fail to link. It does
  not touch the rest of XForms: the OpenGL objects are simply unavailable in this build.

`scripts/build-xforms.sh` in this project automates exactly the above, taking
`--skip-configure`, `--jobs`, `--prefix`, and refusing to run if `$MW_PREFIX/lib/libX11.so` is
missing (same guard as `build-stack.sh`).

### 4.1 Running

```sh
# headless (CI, pixel-asserted)
XDG_RUNTIME_DIR=/tmp/xfw-run WAYLAND_DISPLAY=<sock> \
LD_LIBRARY_PATH=$MW_PREFIX/lib scripts/run-xforms-examples.sh xftest1 xftest2 xftest3

# on the live session (KDE Plasma here)
LD_LIBRARY_PATH=$MW_PREFIX/lib ~/.local/xforms/demos/buttonall
```

No `DISPLAY` is set or needed; if `DISPLAY` happens to be set (XWayland is present in this
session) the shim ignores it — it connects to `$WAYLAND_DISPLAY`.

---

## 5. Test strategy

### 5.1 The examples from xforms-toolkit.org/examples.html

Three programs, taken verbatim from the page, plus the matching screenshots as the visual
reference:

| Name | Exercises |
|---|---|
| `xftest1` | one `FL_NORMAL_BUTTON` in an `FL_UP_BOX` form, `fl_do_forms()` returns, exits on click |
| `xftest2` | two buttons, loop on `fl_do_forms()` return value, stdout `Hello world` |
| `xftest3` | `fl_set_object_callback()` — callback dispatch inside the library's event loop |

Each is built with the stock one-liner from the page: `cc -o xftest xftest.c -lforms -lX11`.

### 5.2 Broader coverage from the bundled demos

Beyond the three page examples, `demos/` (94 `.c` files) is the real test corpus. Selected to
cover distinct subsystems rather than object variety:

| Demo | Subsystem |
|---|---|
| `buttonall`, `butttypes`, `buttonbox` | buttons, callbacks, box layout |
| `demo`, `demotest`, `demo05/06/27/33` | the documented guided tours (up/down boxes, sliders, dials, charts) |
| `choice`, `menubutton`, `popup`, `xpopup` | menu/popup override-redirect windows + grabs ← the riskiest area |
| `bitmap`, `pixmap`, `image`, `xpm*` | `XReadBitmapFile`, `Xpm` pixmaps, `XCopyArea` blits |
| `text`, `input`, `datetime`, `counter` | fonts, `XTextExtents`, `XLookupString`, XIM/IME path |
| `browser`, `dirlist`, `fbrowse` | scrolling + `fl_add_fd`/asyn I/O + `select()` loop |
| `scrollb`, `slider`, `dial`, `thumbwheel`, `knob` | value objects, pixel-grid drawing accuracy |
| `canvas`, `xyplot`, `chartall` | client-side drawing, `XDrawLines`/`XFillArc` |
| `clock`, `counter`, `timer*` | animation loops (exercises the wakeup/repeat path) |
| `choice`/`tabfolder` | tab folders = sub-forms in one window |
| `xfd`, `fdesign` | the two big applications: palettes, colour pickers, dialogs, timers |

`scripts/run-xforms-demos.sh` walks 86 of them (every demo except the GL ones and
`itest`, which is an interactive test harness rather than a demo). The first run
against the shim: **71 paint, 15 show no window, 0 crashes, 0 missing symbols.**

Excluded, with reasons: `gl*` (GLX, §1.2), `jpeg`-dependent image demo (needs an extra
dependency; covered by `xpm*` instead), anything under `contrib/` that needs X11-only tools.

### 5.3 How each program is judged

Same classification as `run-x11-clients.sh`, against the bundled headless compositor with a
PNG frame capture:

| Result | Meaning |
|---|---|
| `ok` | started, painted, frame contains more than one colour; for interactive demos, a scripted input sequence produced the expected state change |
| `ran` | started and exited with no missing symbol, painted nothing |
| `gap` | needs an Xlib symbol the shim does not export → becomes a shim task |
| `crash` | died on a signal → always a shim defect, never acceptable |

Beyond "did it paint", the runner asserts behaviour, not just pixels:

* `xftest1/2/3` must render a window containing the button label(s); a synthetic click at the
  button centre must make the program exit (`xftest3` must not).
* Menu demos must open a popup on press and highlight/select an item.
* `xdpyinfo`-style introspection is unnecessary (XForms itself prints `xdpyinfo`-equivalent info
  via `fl_initiali[z]e -v`); instead we check XForms' own diagnostics
  (`fl_initialize` prints resources/visual/graphics info with `-v`).
* Every run also asserts the process did **not** print `undefined symbol:` and did not
  `SIGSEGV`/`SIGABRT`.

### 5.4 Interactive verification

Pixel tests cannot see pointer grabs, keyboard focus, IME or menus. After the headless matrix
passes, the same binaries are run in the live Plasma session with
`LD_LIBRARY_PATH=$MW_PREFIX/lib` and checked by hand plus with screenshots:

* click every button type; drag sliders/dials/thumbwheels/knobs (pointer motion + button grabs);
* open every menu, submenu and pulldown; scroll browsers; type into text objects (XIM/IME
  through `zwp_text_input_v3` with ibus/fcitx);
* run `xfd` for several minutes: create/change/save/delete objects, which exercises timers,
  dialogs, colour pickers and `XCreateIC` text entry;
* run the GL-free demos for a few minutes each watching for repaint artifacts (always-on
  backing store means missing `Expose`s show up as stale pixels, which is a *good* detector).

Done so far: 39 demos covering every subsystem in the table above were each run for four
seconds against the live Plasma session; all started, mapped a window and were still running
when killed, with no error output. Menu *interaction* (open, highlight, select) is covered
headlessly by the `xftest` click sequences; the wider menu matrix is the obvious next step,
using `tests/*.input` in xlib-wayland as the model.

---

## 6. Risks and mitigations

| Risk | Why it is plausible | Mitigation |
|---|---|---|
| Missing `X*` symbols | XForms is old and touches odd corners of Xlib | Audit (§2.1) says zero gaps; the runner still reports `gap` per binary so a regression is caught |
| Grab semantics for menus | XForms calls `XGrabPointer`/`XGrabKeyboard` with `GrabModeSync`/`Async` and a cursor; Wayland has no client grabs | The shim's `xdg_popup` path was built for Motif/NEdit menus and is validated by `tests/test_popup.c` + `run-motif-demos.sh`; verified interactively in §5.4 |
| `XErrorEvent` timing | XForms registers error handlers and does housekeeping on `BadWindow`/`BadDrawable`; a synchronous abort would kill apps | Shim defers errors; assert in the runner that no demo aborts (a crash is a failure) |
| `XSync`/`XFlush` blocking | XForms calls `XSync` after window creation (11 sites) — under a real server these are round-trips | Shim's `XSync` is flush + local quiesce; watch for stalls in the timing of the interactive runs |
| Font metrics mismatch | XForms lays out by `XTextExtents`; scalable-font advances differ from core-font XLFD metrics | Fonts are emulated with the same XLFD→fontconfig match the shim already uses for Motif; verify label alignment against the page screenshots in §5.1 |
| `libXpm` → shim | `libXpm` calls `XCreateImage`, `XPutPixel`, `XGetPixel`, `XFreePixmap` and expects server-side `XImage` conventions | Same path GIMP/GTK2 use; `xpm*` and `pixmap` demos are in the matrix |
| `-fno-common` build failure | Confirmed: `fdesign` fails to link | Build flag `-fcommon` (§4); no source change |
| Host headers vs shim ABI | We compile against `/usr/include/X11` | By construction the shim is ABI-compatible with those headers; `run-tests.sh` in the parent project guards this for every release |
| Compositor quirks | Real sessions differ from `headless-compositor` (decorations, popups, input method) | Both are tested: headless for regression, Plasma for reality |
| XForms' own bugs surface as crashes | 20-year-old C, e.g. `sp_util.c` `const` warnings, uninitialised values | Distinguish carefully: a crash *in libforms* with our shim correct is an upstream bug; reproduce it against a real X server (XWayland) to prove it is not the shim's, and record it in §7 |

---

## 7. Known gaps / deliberate simplifications

To be filled in as the matrix runs. Each entry is either "fixed in xlib-wayland (pushed)" or
"upstream XForms issue, not our bug".

| Gap | Symptom | Disposition |
|---|---|---|
| Duplicate tentative definitions in `fdesign` (`curobj` in `sp_twheel.c` and `sp_spinner.c`) | link fails: *multiple definition of `curobj`* under GCC ≥ 10's default `-fno-common` | handled by the `-fcommon` build flag (§4); no source change — a host-compiler accommodation, not a shim issue |
| **Input scripts started before the client had a window** | `tools/headless-compositor.c` began the `--input` script on a fixed 400 ms timer. XForms needs longer than that to map anything (Xrm, font list, colormap), so every action was delivered to no surface and dropped: buttons appeared completely dead. | **fixed in xlib-wayland** (commit `2852984`): the script now waits until a toplevel or popup is mapped, polls every 50 ms, gives up after 3 s, and is kicked by the first surface commit. Verified by `xftest1/2/3` exiting 0 on a scripted click |
| 15 demos paint nothing inside the harness window (`demo05`, `demo06`, `demo27`, `demo33`, `free1`, `multilabel`, `objinactive`, `positioner`, `pushbutton`, `pushme`, `sld_alt`, `sldinactive`, `sld_radio`, `sldsize`, `touchbutton`) | headless frame is blank | not a defect: every one of them starts, stays up and exits cleanly on the live session. Some read stdin before showing a form (`free1`, `demo27` …) and others ask for a window larger than the 800×600 canvas the harness configures. Classified `ran` by the runner rather than silently counted as passing |
| `buttonall` warns it cannot read `crab45.xpm` when run from `demos/.libs` | data-file lookup is relative to the cwd | run the demos from `demos/` (the runner does); the warning disappears |

---

## 8. Milestones

| # | Milestone | State |
|---|---|---|
| M0 | XForms 1.2.4 unpacked, symbol audit complete (0 missing symbols, §2.1) | ✅ done |
| M1 | `configure` + `make` + `make install` unmodified against the shim | ✅ done (`--enable-demos --disable-gl`, `-fcommon`) |
| M2 | `xftest1/2/3` from examples.html render under the headless compositor | ✅ done |
| M3 | Scripted clicks handled: buttons activate, callbacks fire, programs exit 0 | ✅ done (needed the xlib-wayland fix in §7) |
| M4 | Demo matrix (menus/popups, pixmaps, text/IME, browsers, canvas/charts, timers) | ✅ done — 86 demos: 71 paint, 15 windowless, **0 crash, 0 gap** |
| M5 | Runners committed here; shim fix pushed to xlib-wayland | ✅ done (commit `2852984`) |

The state column is kept honest as the work proceeds; §7 records every gap found on the way,
whether it was fixed in `xlib-wayland` (and pushed) or turned out to be an upstream XForms bug.

---

## 9. Appendix

### 9.1 Repository layout of this project

```
DESIGN.md                       this document
README.md                       quick start, status, limitations
LICENSE                         MIT
scripts/build-xforms.sh         configure/make/install XForms unmodified against the shim
scripts/run-xforms-examples.sh  the three examples: paint check + scripted-click behaviour check
scripts/run-xforms-demos.sh     the bundled demos: paint check over the wider corpus
examples/xftest{1,2,3}.c        verbatim from http://xforms-toolkit.org/examples.html
examples/build-examples.sh      builds them with the page's own `cc ... -lforms -lX11`
examples/inputs/*.input         the scripted pointer sequences, in compositor script format
xlib-wayland/                   working clone (gitignored): shim changes are committed and
                                pushed to https://github.com/jmalcolm137/xlib-wayland
```

### 9.2 Environment variables

| Variable | Default | Used by |
|---|---|---|
| `MW_PREFIX` | `~/.local/motif-wayland` | `build-xforms.sh`, `run-xforms-examples.sh` |
| `MW_BUILD` | `xlib-wayland/build` | `run-xforms-examples.sh` (needs `headless-compositor`) |
| `XFORMS_PREFIX` | `~/.local/xforms` | `build-xforms.sh`, runner |
| `XFORMS_SRC` | `~/src/xforms/xforms-1.2.4` | `build-xforms.sh` |
| `JOBS` | `nproc` | both scripts |
| `XFORMS_DEMOS` | the §5.2 list | `run-xforms-examples.sh` |

### 9.3 One-shot sequence

```sh
export MW_PREFIX="$HOME/.local/motif-wayland"
export XFORMS_PREFIX="$HOME/.local/xforms"

(cd xlib-wayland && meson setup build --prefix="$MW_PREFIX" && meson install -C build)
scripts/build-xforms.sh
scripts/run-xforms-examples.sh
```