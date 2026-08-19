# dirty-state probe — LINUX arm (GTK4 / libadwaita, the lane's container)

Probe only. Nothing here ships; `docs/` untouched; no repo file modified.
Repo HEAD at probe time: `1d2cf95`.

Environment measured: `kaya-linux:latest` (built from `tools/linux/Dockerfile`,
debian trixie @ `sha256:fac46bff…`), started as a throwaway container
`kaya-dirty-probe` with the repo at `/work` and the scratchpad at `/probe`.

    GTK4        4.18.6   (pkg-config --modversion gtk4)
    libadwaita  1.7.6    (pkg-config --modversion libadwaita-1)
    icon theme  Adwaita 48.1 (adwaita-icon-theme), 758 icon names
    Rust crates gtk4 0.11.4 (features = ["v4_10"]), libadwaita 0.9.2 (v1_4)
                — crates/kaya/Cargo.toml:123,134

Both session backends the lane actually runs were measured: X11 under
`xvfb-run` and Wayland under headless `sway`, started exactly as
`tools/linux/run-suites.sh:168-206` starts it. The a11y reads ran inside
`tools/linux/a11y-leg.sh`, the lane's own per-leg a11y session.

Probe sources (throwaway):
`/private/tmp/claude-501/-Users-akhilindurti-Projects-kaya/24aa5ebf-e439-4206-9ba0-de67540e4b06/scratchpad/dirtyprobe/ (gone)`
— `probe.c`, `x11-leg.sh`, `wayland-leg.sh`, `wl-inner.sh`, `toggle-leg.sh`,
`deep-leg.sh`, `deep_atspi.py`, `gir_props.py`, `icons.py`; outputs in `out/`.

---

## VERDICT

1. **GTK4 has no window-level modified/edited/dirty affordance, at any layer.**
   Not in GTK 4.18.6, not in libadwaita 1.7.6, not in the display-server
   protocols. There is no linux equivalent of `NSWindow.isDocumentEdited`.
   Whatever `dirty` lowers to on this platform, **kaya draws it**.
2. **A marker composed into the title string works end to end** and is
   observable at three independent layers, live, in both directions, on both
   session backends. It costs nothing new to build and nothing new to read.
3. **The GNOME idiom is NOT a title marker** — it is a bullet *label* beside the
   title inside the header bar, with the window title string left clean. Read
   from GNOME Text Editor's own `.ui` and `.c`. That route works here too, and
   is observable only if kaya sets an accessible label on the marker widget —
   which it should do anyway, and already has the machinery for.
4. **The decision is cross-platform, not linux-local.** Composing the marker
   into the title changes what `expect_title` reads on linux. If another
   backend lowers `dirty` to chrome that leaves its title alone, the same
   `.steps` line wants two different strings — and `tools/scenes/*.steps` are
   shared verbatim, byte-for-byte (invariant 6). See §5.

---

## 1. What GTK4 offers beyond title text — nothing

### 1a. The exhaustive property sweep

Read from the container's own GIR (`/usr/share/gir-1.0/{Gtk-4.0,Adw-1,Gdk-4.0}.gir`),
which is the same description the `gtk4`/`libadwaita` Rust crates are generated
from, so the Rust surface cannot have more.

`Gtk.Window` full property list, 4.18.6:

    application, child, decorated, default-height, default-widget,
    default-width, deletable, destroy-with-parent, display, focus-visible,
    focus-widget, fullscreened, handle-menubar-accel, hide-on-close,
    icon-name, is-active, maximized, mnemonics-visible, modal, resizable,
    startup-id, suspended, title, titlebar, transient-for

`Gdk.Toplevel`: `decorated, deletable, fullscreen-mode, icon-list, modal,
shortcuts-inhibited, startup-id, state, title, transient-for`.
`GdkToplevelState` (gdktoplevel.h:107+) is MINIMIZED / MAXIMIZED / STICKY /
FULLSCREEN / ABOVE / BELOW / FOCUSED / TILED / *_TILED / *_RESIZABLE /
SUSPENDED. No "modified", no "urgent", no "attention".

`Adw.Window`, `Adw.ApplicationWindow`: `adaptive-preview, content,
current-breakpoint, dialogs, visible-dialog`. `Adw.HeaderBar`:
`centering-policy, decoration-layout, show-back-button,
show-end-title-buttons, show-start-title-buttons, show-title, title-widget`.
`Adw.WindowTitle`: `title, subtitle`.

Searching every class/interface/property/method/signal in all three GIRs for
`modified|unsaved|edited|dirty|attention|urgen` returns, in full:

    Gtk.CellArea.edited-cell            (cell editing, unrelated)
    Gtk.CellRendererAccel.accel-edited  (unrelated)
    Gtk.CellRendererText.edited         (unrelated)
    Gtk.StackPage.needs-attention       (a stack page badge)
    Gtk.TextBuffer.{get,set}_modified   (a DOCUMENT-MODEL flag, no chrome)
    Adw.TabPage.needs-attention         (a tab badge)
    Adw.ViewStackPage.needs-attention   (a view-switcher badge)

`GtkTextBuffer:modified` is the closest name in the toolkit and is the exact
opposite of what is wanted: it is the app's own bookkeeping flag on a buffer,
it drives no chrome at all, and the toolkit never surfaces it. The three
`needs-attention` properties are page/tab badges inside a window, not window
chrome, and their meaning is "look here", not "unsaved".

grep over `/usr/include/libadwaita-1/` for the same words: **zero hits.**

### 1b. Nothing at the display-server layer either

- **Wayland.** `xdg_toplevel` carries exactly two identity strings —
  `set_title` ("may be used to identify the surface in a task bar, window
  list, or other user interface elements provided by the compositor") and
  `set_app_id`. There is no state, flag, or hint for document modification, in
  xdg-shell or anywhere in `/usr/share/wayland-protocols/{stable,staging,unstable}`.
- **X11.** GTK4 exposes one attention-adjacent call and it is backend-private:
  `gdk_x11_surface_set_urgency_hint` (`gdk/x11/gdkx11surface.h:114`). It is
  X11-only, it means "demands attention" (the WM flashes the task entry), and
  it has no Wayland counterpart, so it cannot carry a uniform semantics.

**Consequence.** On mac the platform owns a dirty bit and the app sets it. On
linux there is no bit to set. The window's identity string and the widgets
kaya puts in the header bar are the whole vocabulary.

### 1c. kaya already owns the titlebar, which is what makes any of this cheap

`install_nav_chrome` (`crates/kaya/src/gtk.rs:747-761`) calls
`window.set_titlebar(Some(&header))` with a `GtkHeaderBar` for **every** kaya
window — the primary (`gtk.rs:4589`) and every aux window (`gtk.rs:3393`).
Probe confirms it at runtime: `gtk_window_get_titlebar()` reports
`GtkHeaderBar`, and the capture below shows GTK drawing the bar itself under
both backends. So there is no server-side titlebar to fight: any marker kaya
wants to draw, it can draw.

## 2. What the GNOME HIG currently says — and what GNOME apps actually do

**The current HIG says nothing.** The GNOME HIG at developer.gnome.org/hig
(the GNOME 40+ rewrite) has no page on saving, document state, or unsaved
changes. Its Patterns > Containers > Header Bars page covers layout, button
grouping and alignment and never mentions document state; the Windows page
covers primary/secondary windows, sizing and restoration and never mentions
titles-as-state. Fetched and checked both.

**The asterisk rule is dead.** "When a document has pending changes, insert an
asterisk at the beginning of the window title (`*AnnualReport`)" is **GNOME
HIG 2.2.1**, i.e. the GNOME 2 era. It did not survive into the current HIG.

**The living convention is a marker widget in the header bar, not a title
marker.** GNOME Text Editor — the app usually cited for "GNOME shows a dot now"
— never puts the marker in the window title. Its window title is
`g_strdup_printf(_("%s (%s) - Text Editor"), title, subtitle)`, with no marker
anywhere in it; U+2022 does not occur in `editor-window.c` at all. The dot is a
**GtkLabel in the header bar**, from `editor-window.ui`:

    <object class="AdwHeaderBar" id="header_bar">
      <property name="title-widget">
        <object class="GtkBox"><child>
          <object class="GtkCenterBox"><child type="start">
            <object class="GtkLabel" id="is_modified">
              <property name="halign">end</property>
              <property name="hexpand">true</property>
              <property name="label">•</property>
              <property name="visible">false</property>
            </object>
          </child></object>
        </child></object>
      </property>
    </object>

with `visible` bound to the page's `is-modified`. Anyone reasoning from "GNOME
uses •" is reasoning from a screenshot; the point the screenshot hides is
*where* the bullet lives — beside the title, not in it.

**Do not confuse this with the tab marker.** `editor-window.c` also has

    static gboolean modified_to_icon (…)
    { … icon = g_themed_icon_new ("document-modified-symbolic"); … }

    g_object_bind_property (page, "is-modified", tab_page, "icon",
                            G_BINDING_SYNC_CREATE, modified_to_icon, …);

but its target is `AdwTabPage:icon` — the **tab's** icon, one of the tab
properties §1a's sweep turned up. Window chrome gets the label; tabs get the
icon. kaya has no tabs, so the icon path is not kaya's path — which is
convenient, because `document-modified-symbolic` is **not in the lane image's
icon theme**: Adwaita 48.1 has 758 icon names and none match
`modif|unsaved|dirty` (`icons.py`, `has_icon` = False; Text Editor ships it in
its own GResource). Following the window idiom costs kaya no asset at all — the
marker is a label with a character in it.

## 3. How kaya sets titles today, and what a marker renders like

### 3a. Today's code

- Write: `gtk.rs:3337-3350`, `ApplyOp::SetWindowProp` / `WindowProp::Title` —
  stores into `core.window_titles` and calls `target.set_title` *only when no
  navigation entry covers the window*.
- **There are four `set_title` call sites on a window** (`gtk.rs:948`, `989`,
  `994`, `3348`). Three of them are in `refresh_nav`, which rewrites the title
  on every push/pop: the covering entry's title (948, 989) or the window's own
  title restored at pop (994).
- Read: `gtk.rs:5949-5957`, `Stage::window_title` — `gtk_window_get_title()`.
- Prop vocabulary: `WindowProp` (`crates/kaya/src/protocol.rs:1076-1105`) =
  Title, Width, Height, VetoClose, SectionsPresentation, ListDetail; wire enum
  `wprop` (`crates/kaya/src/spec.rs:1684-1694`) = title 1 … list_detail 6, so
  a `dirty` prop is `wprop 7`, Bool-valued.
- Verb: `Step::ExpectTitle` (`crates/kaya/src/harness.rs:2077-2095`) polls
  `stage.window_title(id)` and compares byte-for-byte.

### 3b. What a composed marker actually renders like

Real windows, captured. `PROBE_MARKER` = U+2022 + space.

**X11 (Xvfb), title `"• window probe"`** — `out/marker-title-x11-header.png`:
the bullet sits inline before the bold title, centred in the client-drawn
header bar; window controls at the right. Byte dump confirms the title is
`e2 80 a2 20 77 69 6e 64 6f 77 20 70 72 6f 62 65` — GTK stores and returns it
untouched.

**Wayland (headless sway), same title** — `out/marker-title-wl.png`, a full
1280x720 grab via `grim`: a floating, rounded, client-decorated window reading
`• window probe` in its header, with sway drawing **no** server-side titlebar
(GTK negotiated CSD, and sway respected it). The compositor's own view, from
sway's IPC tree:

    node type=floating_con app_id='dev.kaya.dirtyprobe'
         name='• window probe' shell='xdg_shell'

so the marker reaches the compositor — meaning it would appear in any task
bar, window list, or overview, which is the point of the affordance.

Alternatives rendered for comparison:
`out/headerbar-widget-x11-header.png` — a dim bullet as its own label beside
the title, i.e. the GNOME Text Editor idiom (§2), title string clean;
`out/adw-subtitle-wl.png` — AdwWindowTitle with subtitle "Unsaved changes",
also a genuine GNOME pattern and the most legible of the three;
`out/icon-labeled-deep-header.png` — a symbolic icon packed at the header's
end, which is what Text Editor does for *tabs*, shown here only to price it.

**Headless capture was possible on both.** X11 via ImageMagick `import`;
Wayland via `grim`, which is not in `tools/linux/Dockerfile` and which I
installed into the throwaway container's writable layer only (the image is
untouched). If this milestone wants pixel evidence from the wayland leg, `grim`
is a one-line addition to the image.

## 4. OBSERVABILITY — how a harness leg reads the chrome on linux

### 4a. What the lane can read today

Two independent readers already exist:

- **`Stage::window_title`** (`gtk.rs:5949`) — an in-process
  `gtk_window_get_title()`. Note the honest caveat: on mac the equivalent read
  goes to the real title bar, but here it reads GTK's own property store, i.e.
  kaya's own write coming back. Measured, it is faithful — the property, X11's
  `_NET_WM_NAME` and sway's IPC `name` agreed exactly, every time — but it is
  faithful *because* GTK renders from the same property. A lowering that
  composed the marker at render time (a title-widget) would leave this read
  passing while the chrome showed nothing. That is the trap.
- **`atspi_collect`** (`gtk.rs:6904+`) — a real out-of-band AT-SPI client over
  D-Bus, walking this process's tree to depth 24 and matching on
  `atspi::Role`. It currently maps widget kinds only; it does not look at
  `Role::Frame`. Adding a frame-level read is a small extension of code that
  already works.

### 4b. Is the marker visible to AT-SPI? Measured, for each candidate

Under `tools/linux/a11y-leg.sh`, both backends. `frame` is the window node.

| lowering | AT-SPI frame name | where the marker shows | name-addressable? |
|---|---|---|---|
| marker in title | `'• window probe'` | on the frame itself | **yes, free** |
| bullet label, no a11y label (the GNOME idiom, as-is) | `'window probe'` | `label name='• '`, 6 levels down | no — you would match a lone bullet |
| **bullet label + a11y label** | `'window probe'` | `label name='Unsaved changes'` | **yes** |
| AdwWindowTitle subtitle | `'window probe'` | `label name='Unsaved changes'`, nested | by string, if you walk |
| symbolic icon, no a11y label | `'window probe'` | `image name=''` — **anonymous** | **no** |
| symbolic icon + a11y label | `'window probe'` | `image name='Unsaved changes'` | **yes** |

The third row is the important one. Adding
`gtk_accessible_update_property(GTK_ACCESSIBLE_PROPERTY_LABEL, "Unsaved changes")`
to the marker widget turns a node nobody can address into a named one — and the
accessible name **replaces** the visible "•" rather than appending to it, which
is what a screen reader should say. kaya already sets
`GTK_ACCESSIBLE_PROPERTY_LABEL` for its universal a11y props, so this is
machinery it has. Without the label the GNOME idiom as GNOME ships it is
**unreadable to the lane and to a real screen reader alike** — a bullet
character is not a name — and the only assertion left would be structural
("some label exists inside the titlebar panel"), which collides with anything
else a header ever holds.

### 4c. Does a toggle propagate, live, in both directions?

The scene will flip dirty on and off. Probe flipped the title at t=4/8/12 and
read at t=2/6/10/14 (`out/title-toggle-toggle.reads`). Every layer tracked
every flip, clean→dirty and dirty→clean:

    t=2  clean  _NET_WM_NAME "window probe"              frame name 'window probe'
    t=6  dirty  _NET_WM_NAME "\342\200\242 window probe"  frame name '• window probe'
    t=10 clean  _NET_WM_NAME "window probe"              frame name 'window probe'
    t=14 dirty  _NET_WM_NAME "\342\200\242 window probe"  frame name '• window probe'

For the marker-widget route (`out/dot-toggle-toggle.reads` for the labelled
bullet label, `out/icon-toggle-toggle.reads` for the icon), the node appears in
and disappears from the AT-SPI tree in lockstep with `gtk_widget_set_visible`,
while the frame name and `_NET_WM_NAME` stay clean throughout. So the scene's
assertion is presence-of-a-named-node: `Unsaved changes` is in the tree when
dirty and absent when clean, both directions, every phase.

### 4d. A trap for whoever debugs this later

`tools/linux/atspi_probe.py` truncates its walk at **depth 8**. Under an
`AdwApplicationWindow` + `AdwHeaderBar`, the header's own labels sit at depth
**15**, below that horizon — my first read of the `adw-window` arm showed the
subtitle "missing" purely for that reason, and a re-run with a depth-24 walker
(`deep_atspi.py`, matching `atspi_collect`'s own limit) found it exactly where
it should be. The debug probe is shallower than the real reader. Anyone
comparing the two will conclude the wrong thing.

## 5. The consequence this arm has to hand back

`expect_title` compares byte-for-byte, and `tools/scenes/*.steps` are shared
verbatim across every platform with identical expected strings (invariant 6).
So:

- If linux composes the marker into the title, then on a dirty window the
  linux `expect_title` wants `"• window probe"`.
- If some other backend lowers `dirty` to a platform bit that leaves the title
  alone, its `expect_title` still wants `"window probe"`.
- One shared `.steps` line cannot be both. Divergence here is invariant 1
  divergence: the same declaration observable as two different things.

Two ways out, both cheap on linux, and the choice is not linux's to make alone:

- **(a) Keep titles clean everywhere; add a verb.** `dirty` lowers to chrome
  each backend picks, and a new `expect_dirty <bool>` asks each backend for
  its own answer. On linux that is a bullet label in the header bar carrying
  an accessible label, read through the AT-SPI reader that already exists —
  §4b row 3, measured working, toggling both ways. This is also exactly the
  GNOME-idiomatic lowering (§2), and it leaves every existing `expect_title`
  leg untouched.
- **(b) Compose into the title everywhere and say so in the spec.** Free to
  observe on linux (§4b row 1, §4c). But it forces a title-string convention
  onto every platform, and on linux it has a specific hazard worth pricing:
  **there are four `set_title` call sites** (`gtk.rs:948, 989, 994, 3348`) and
  three of them are on the navigation path. A marker composed at only the prop
  site would be silently wiped by the next push or pop. That is a guard the
  milestone would have to build — a single compose-and-write chokepoint that
  the other three sites cannot bypass — rather than a thing that just works.

My reading of the measurements: (a) is the better bet on this platform. It
matches what GNOME apps actually do, it keeps the shared scenes' title
assertions honest, it needs no asset (the marker is a label with a character in
it), and its whole cost is one widget plus one
`gtk_accessible_update_property` call — both measured working. But (b) is
genuinely free to observe here, so if another arm reports that its platform can
express dirty only through the title, linux can follow without difficulty.

Whichever wins, one thing is linux-specific and should not be forgotten: the
marker widget needs the accessible label for its own sake. A bullet with no
name is a mark only a sighted user gets, and kaya's a11y milestone made
"every kind carries the universal a11y props" a standing rule.

## 6. Facts most likely to be wanted verbatim

- GTK 4.18.6 / libadwaita 1.7.6 / Adwaita icons 48.1; crates `gtk4 0.11.4`
  (v4_10), `libadwaita 0.9.2` (v1_4).
- `Gtk.Window` has 23 properties and none is modified/edited/dirty.
- `xdg_toplevel` has `set_title` and `set_app_id` and nothing else identity-ish.
- `gdk_x11_surface_set_urgency_hint` is the only attention-adjacent call and is
  X11-only.
- GNOME Text Editor sets no marker in `gtk_window_set_title`; U+2022 does not
  occur in `editor-window.c`. Its window marker is a `GtkLabel id="is_modified"
  label="•" visible=false` inside the AdwHeaderBar's title-widget, with
  `visible` bound to `is-modified`. `document-modified-symbolic` is used for
  `AdwTabPage:icon` only — the tab, not the window.
- `document-modified-symbolic` is **absent** from Adwaita 48.1, so the tab-icon
  route would need a shipped asset; the window-label route needs none.
- The current GNOME HIG has no page on saving, unsaved changes, or document
  state. The asterisk-in-title rule is GNOME HIG 2.x and is gone.
- A U+2022 title marker round-trips byte-exact through GTK, `_NET_WM_NAME`,
  sway's IPC and the AT-SPI frame name, on both session backends, live in both
  directions.
- An unlabelled marker widget is anonymous to AT-SPI (`label name='• '`,
  `image name=''`). With `GTK_ACCESSIBLE_PROPERTY_LABEL` it becomes
  `name='Unsaved changes'`, the accessible name replacing the glyph.
- `tools/linux/atspi_probe.py` walks to depth 8; `gtk.rs:atspi_collect` walks
  to depth 24; Adw header content sits at depth ~15.

---

## Cleanup

- Container `kaya-dirty-probe` stopped and removed.
  `docker ps -a --filter name=kaya-dirty-probe` returns nothing;
  `docker ps` returns nothing at all. `grim` was installed only into that
  container's writable layer, so it went with the container.
  `kaya-linux:latest` (`ec8da69eac61`) and `tools/linux/Dockerfile` unchanged.
- No stray host processes: `ps -Ao pid,etime,pcpu,command` filtered for
  `dirtyprobe|/probe/|sway|Xvfb|xvfb-run|at-spi|wl-inner|toggle-leg` is empty.
  Every Xvfb, sway, dbus and at-spi-bus-launcher instance lived inside the
  container and died with it.
- Disk: `scratchpad/dirtyprobe/ (gone)` was **468K** at peak (344K of it outputs) and
  is **deleted**. Kept beside this report: `dirty-probe-linux-evidence/`,
  **72K**, 14 files — the five renders and the nine measurement dumps this
  report quotes, so the claims stay checkable. This report is 24K.
- The repo was mounted read-write at `/work` but never written: the probe read
  `tools/linux/a11y-leg.sh` and `tools/linux/atspi_probe.py` and wrote only to
  the scratchpad mount. `git status --porcelain` shows one modified file,
  `tools/guest/record-win/Program.cs` — **not this arm's**: it is WinUI
  recorder work (window-class identification), its mtime precedes this probe's
  first container run, and nothing here touches Windows. Left untouched.
