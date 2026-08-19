# Toolbar / chrome research — Linux (GTK4 + libadwaita)

Answering the four questions in docs/chrome-plan.md §C2 for the GTK arm.
Evidence tiers: **[DOC]** = primary platform documentation (URL + API +
version); **[MEASURED]** = I ran it in this repo's own lane image today;
**[INFER]** = inference, flagged as such.

## 0. The versions every claim below is pinned to

| thing | version | how pinned |
|---|---|---|
| libadwaita (runtime + dev) | **1.7.6** (`1.7.6-1~deb13u1`) | **[MEASURED]** `docker run --rm kaya-linux:latest pkg-config --modversion libadwaita-1` → `1.7.6`; `dpkg -l` → `libadwaita-1-0:arm64 1.7.6-1~deb13u1` |
| GTK | **4.18.6** (`4.18.6+ds-2`) | **[MEASURED]** same command → `4.18.6` |
| adwaita-icon-theme | **48.1-1** | **[MEASURED]** `dpkg -l` |
| `libadwaita` Rust crate | **0.9.2**, `features = ["v1_4"]` | crates/kaya/Cargo.toml:175 — so the compile-time API floor kaya may use is **libadwaita 1.4**, deliberately below the image's 1.7 |
| `gtk4` Rust crate | **0.11.4**, `features = ["v4_10"]` | crates/kaya/Cargo.toml:151 |
| base image | `debian@sha256:fac46bf…` (trixie, digest-pinned) | tools/linux/Dockerfile:23 |

Everything below that says "the platform" means **GTK 4.18.6 +
libadwaita 1.7.6, with the API restricted to what the v1_4 feature
gate exposes**. Both the constructs this report recommends
(`AdwToolbarView`, `AdwToolbarStyle`, `AdwHeaderBar`) are **1.4** API
**[DOC]**, so they are inside the existing gate — no Cargo.toml move.

Probe scripts (read-only, outside the repo, all run against
`kaya-linux:latest` under Xvfb): `…/scratchpad/chrome/adw_probe.py (gone)`
through `adw_probe9.py` (+ the `.sh` wrappers), `a11y_app.py`,
`a11y_read.py`, `a11y_run.sh`; renders in `…/scratchpad/chrome/out/ (gone)`.

## 1. What gtk.rs builds today (the starting position)

Read out of crates/kaya/src/gtk.rs. This matters because the answer to
Q3/Q4 turns on which container the window uses.

- **`adw::init()` IS called** (gtk.rs:6660, inside `connect_activate`,
  before any Adw widget is constructed). So **libadwaita's stylesheet is
  live** for the whole app, not just GTK's built-in Adwaita. This is the
  single most important existing fact for the "modern look" question.
- The primary window is a **`gtk4::ApplicationWindow`** (gtk.rs:6664),
  aux windows are `gtk4::Window`. *Not* `adw::ApplicationWindow`.
- Chrome is a plain **`gtk4::HeaderBar`** installed with
  `window.set_titlebar(Some(&header))` (`install_nav_chrome`,
  gtk.rs:1471-1512). It already uses the promotion mechanism this report
  is about: `header.pack_start(&back)` for the back button, and
  `set_title_widget` for a `CenterBox` holding the dirty marker + a
  title label bound to `window:title`.
- **Menus / the command catalog** (gtk.rs:2017-2450): one `gio::Menu`
  per window rendered by a `gtk4::PopoverMenuBar` in a strip *above* the
  mounted root; every actionable item is a window-scoped
  **`gio::SimpleAction` named `win.kmi-<id>`**; enablement is
  `action.set_enabled(effective)` where `effective` =
  `menu_effective_enabled()` = the AND of the item's own flag and every
  grouping ancestor's (gtk.rs:2109-2118); shortcuts ride
  `set_accels_for_action`; the semantic symbol is already resolved to an
  Adwaita icon name by `symbol_icon_name()` (gtk.rs:125).
- **Sections** (`refresh_sections`, gtk.rs:1769-1865): a `gtk4::Stack`
  plus either a `gtk4::StackSwitcher` (hint auto/bar — packed into a
  vertical `Box` in the *content*, halign Center, **not** in the header
  bar) or a `gtk4::StackSidebar` (hint sidebar — a horizontal `Box`).
- **List-detail**: `adw::NavigationSplitView` inside an
  `adw::BreakpointBin`, set as the window's content
  (`refresh_nav`, gtk.rs:1590-1737). The `AdwNavigationPage`s carry the
  **raw scene root** — no `AdwHeaderBar` inside them — and gtk.rs
  already documents the consequence in a comment at :1717-1728:
  libadwaita's own back button is drawn *inside a header bar it owns
  (an AdwHeaderBar in the page, normally via AdwToolbarView)*, so kaya
  had to keep drawing its own.

So: kaya on Linux today is a **titlebar-based** app (GtkHeaderBar in the
window's titlebar slot), with libadwaita's stylesheet loaded and one
libadwaita layout widget in use.

---

## Q1 — what an ordered promotion list lowers to, and whether a tall variant exists

### The lowering

`AdwHeaderBar` / `GtkHeaderBar` **`pack_start()` / `pack_end()`**, in
list order, one `GtkButton` per promoted catalog item. **[DOC]**
- `gtk_header_bar_pack_start` / `pack_end`:
  https://docs.gtk.org/gtk4/class.HeaderBar.html — "Adds child to
  self, packed with reference to the start/end of the header bar."
- `adw_header_bar_pack_start` / `pack_end`:
  https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.7/class.HeaderBar.html
  — "Adds `child` to `self`, packed with reference to the start of the
  `self`." (`AdwHeaderBar` is "typically used as a top bar within
  `AdwToolbarView`.")
- **[MEASURED]** both classes expose exactly `pack_start`, `pack_end`,
  `remove` and nothing else for children (probe2: the packing API dump).

The button's `action-name` should be the catalog item's existing
`win.kmi-<id>` — see Q2 (enablement).

### Is there a tall / extended / modern variant?

**No. Not as a default, not as an enum, not as a window flag.**
**[MEASURED]** — the header bar's height is *46 px, identically*, in
every configuration the plan's "extended" idea could mean:

| configuration | min | nat | allocated |
|---|---|---|---|
| `AdwHeaderBar` in `AdwToolbarView`, **FLAT** (the default) | 46 | 46 | 46 |
| `AdwHeaderBar` in `AdwToolbarView`, **RAISED** | 46 | 46 | 46 |
| `GtkHeaderBar` via `set_titlebar` (**what kaya does today**) | 46 | 46 | 46 |
| `AdwHeaderBar` + one symbolic button packed | 46 | 46 | 46 |

(adw_probe3.py, `widget.measure(VERTICAL, -1)` after presenting an
800×600 window under Xvfb, libadwaita 1.7.6 / GTK 4.18.6.)

There is no `AdwToolbarStyle` member that changes height, no
"unified"/"expanded" size class, and **GTK 4 deleted `GtkToolbar`
entirely** — **[MEASURED]** `hasattr(Gtk, 'Toolbar') == False` on
4.18.6. **[DOC]** the GTK 3→4 migration guide, verbatim: "Toolbars were
using outdated concepts such as requiring special toolitem widgets.
Toolbars should be replaced by using a `GtkBox` with regular widgets
instead and the "toolbar" style class."
https://docs.gtk.org/gtk4/migrating-3to4.html — note what went with it:
GtkToolbar's arrow-overflow menu was the last automatic overflow GTK
had, and the guide offers no replacement for it.

**The two knobs that DO exist on the top bar, and what they actually
control:**

1. **`AdwToolbarView:top-bar-style`** (`AdwToolbarStyle`, **since 1.4**).
   **[MEASURED]** members on 1.7.6: `FLAT = 0`, `RAISED = 1`,
   `RAISED_BORDER = 2`. **[MEASURED]** the property's default is
   `ADW_TOOLBAR_FLAT` — both the GParamSpec default (`default=0`) and
   the live value off a fresh `Adw.ToolbarView()`.
   **[DOC]** https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.7/enum.ToolbarStyle.html
   — verbatim: FLAT = "No background, shadow only for scrolled content";
   RAISED = "Opaque background with a persistent shadow";
   RAISED_BORDER = "Opaque background with a persistent border". The
   same page says FLAT "suits simple content like status pages or
   preferences pages, and **windows with sidebars should always use
   it**". **This is a BACKGROUND/SEPARATOR knob only — it changes zero
   pixels of height** (measured above).
2. **`AdwToolbarView:extend-content-to-top-edge`** (gboolean, **since
   1.4**, **[MEASURED]** default `False`). This is the real
   Linux analogue of the plan's C1 `extended`: the content is drawn
   *under* the top bar rather than below it, and the top bar floats over
   it. **[DOC]** same class page, `property.ToolbarView.extend-content-to-top-edge`.
   It is a **window-content-container flag, not a toolbar style**, and it
   is C1 territory — C1 is deferred, so it is out of scope for C2. Note
   it also does not change the bar's height; it changes where the
   content starts.

**[DOC] What GNOME's HIG says**, verbatim from
https://developer.gnome.org/hig/patterns/containers/header-bars.html —
"Header bars are a standard element that span the top of windows";
"Header bars should only contain a small number of controls"; menus are
"typically placed at the end"; and label-only buttons "should generally
be avoided for primary window header bars". The page has **no** taller,
expandable or multi-row header bar configuration — the "tall unified
toolbar" genre the plan points at is a macOS shape with no GNOME
counterpart.

**Verdict Q1: the modern/tall/extended treatment on Linux is
`default-of-construct` for the flat/merged half (top-bar-style FLAT is
the constructor default) and `nonexistent` for the tall half.**

---

## Q2 — what comes free from the list alone, and what does not

### FREE (the platform does it; kaya writes no code)

| thing | evidence |
|---|---|
| **Enablement propagation.** A `GtkButton` with `action-name = "win.kmi-<id>"` goes insensitive the instant that `GSimpleAction` is disabled, and sensitive again when it is re-enabled — zero per-button code. | **[MEASURED]** probe4/A: `enabled=True → sensitive=True`; `set_enabled(False) → sensitive=False`; `set_enabled(True) → sensitive=True`. **[DOC]** `GtkActionable` / `gtk_actionable_set_action_name` — https://docs.gtk.org/gtk4/iface.Actionable.html |
| **One source of truth.** kaya's catalog items ALREADY are those actions (`win.kmi-<id>`, gtk.rs:2246-2340) and `menu_effective_enabled()` already folds in the ancestor AND. So the plan's "disable the menu item, observe the button disabled" round-trip is satisfied by binding the button's `action-name` and nothing else. | **[MEASURED]** above + gtk.rs:2109-2118, 2219 |
| **Activation.** The same action fires from the menu row, the accelerator, the context popover and now the toolbar button — kaya's "one dispatch path" (gtk.rs:2034) extends for free. | **[INFER]**, but it is the same `GAction` object; no new route exists to diverge |
| **Flat button styling inside the bar.** The `.toolbar` appearance "is also used by AdwHeaderBar, GtkHeaderBar, GtkActionBar and GtkSearchBar **automatically**"; it makes buttons flat and "ensures 6px margins and spacing between widgets." | **[DOC]** https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.7/style-classes.html |
| **Scroll-edge effect.** With `AdwToolbarView` in the default FLAT style, a shadow appears under the top bar **only when the content is scrolled**. `AdwToolbarView` "manages undershoots automatically based on presence and visibility of top and bottom bars." | **[MEASURED]** probe7 + pixel read: flat at scroll 0 → rows 40-61 all gray 250 (no separator at all); flat scrolled → rows 51-54 dip to 226/242/245/248 then back to 250. **[DOC]** style-classes.html (`.undershoot-*`) and `ADW_TOOLBAR_FLAT` = "No background, shadow only for scrolled content" — https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.7/enum.ToolbarStyle.html |
| **Merged / flat chrome.** Also automatic, and it is the DEFAULT — see Q3. | **[MEASURED]** probe8 |
| **Window-drag from the bar.** `AdwHeaderBar`'s CSS node is a `windowhandle`, so the bar is draggable and double-click-maximizes with no drag-region code (this is where the WinUI arm has to work and Linux does not). | **[MEASURED]** probe5 tree dump: `WindowHandle > CenterBox > …`. **[DOC]** class.HeaderBar.html CSS nodes |
| **Back button, in the split-view layout.** An `AdwHeaderBar` inside an `AdwNavigationSplitView` page mints its own `AdwBackButton` (`action='navigation.pop'`, `icon='go-previous-symbolic'`), **mapped only while collapsed**. | **[MEASURED]** probe5/D: expanded → `mapped=False`; `set_collapsed(True)` → `mapped=True`. |

That last row is worth a second look: gtk.rs:1665-1692 hand-rolls exactly
this — a `connect_collapsed_notify` deferred through `idle_add_local_once`
that flips `back.set_visible(collapsed && covers)` — and gtk.rs:1717-1728
already suspects why ("libadwaita draws that button inside a header bar IT
owns … normally via AdwToolbarView"). **[MEASURED]** probe5/D2 confirms the
other half: with the pages carrying a raw child, as kaya does today, the
whole window tree contains **no back button of any kind**. So the comment's
diagnosis is now measured, not inferred.

### NOT FREE (kaya must write it)

| thing | evidence |
|---|---|
| **Icon and label.** A `GtkButton` bound to an action gets **nothing** from it: `label=None icon=None child=None`. The promotion lowering must set the icon from the item's symbol (`symbol_icon_name()`, already in gtk.rs:125) or the label. | **[MEASURED]** probe4/A |
| **The accessible name — and this one is a trap.** An icon-only button with only `action-name` publishes `role='button' name=''` on the AT-SPI bus. A screen reader says nothing and `expect_toolbar_item i "label"` reads the empty string. A **tooltip** fills it (`name='Find'`), an explicit `Gtk.AccessibleProperty.LABEL` fills it (`name='Copy'`), a label button fills it (`name='Export'`). | **[MEASURED]** AT-SPI walk of a live header bar under `GTK_A11Y=atspi` (`a11y_app.py` + `a11y_read.py`) |
| **Overflow. There is none — see below.** | |
| **Ordering across start/end.** `pack_start`/`pack_end` are the only placement API; an ordered list maps to repeated `pack_start` (which appends after previously packed start children). | **[DOC]** class.HeaderBar.html |

### Overflow, specifically: GTK gives you nothing, and the failure is a window that will not shrink

**[MEASURED]** probe4/B — 24 icon buttons packed into a `GtkHeaderBar` on a
window asking for 300px wide:

```
headerbar with 24 buttons: min_width=1155 nat_width=2019
window asked for 300 wide; actual window width = 1155
```

GTK does not elide, does not scroll, does not synthesize a menu. It
**raises the window's minimum width** to fit them all (~48px per button)
and the window becomes unshrinkable. There is no overflow construct
anywhere in the stack: **[MEASURED]** the only `*overflow*` symbols in GTK
4.18 are `Gtk.Overflow` and `Gtk.InscriptionOverflow` (clipping enums), and
`Adw` 1.7.6 has none at all; `hasattr(Gtk, 'Toolbar') == False` — GTK 4
deleted `GtkToolbar` **[DOC]** https://docs.gtk.org/gtk4/migrating-3to4.html.

What GNOME does instead **[DOC]**:
- HIG, Header Bars: "Header bars should only contain a small number of
  controls" — explicitly so "the window can be resized to narrow widths."
  https://developer.gnome.org/hig/patterns/containers/header-bars.html
- The remainder goes into an app-built primary menu, "typically placed at
  the end" — a `GtkMenuButton` over a `GMenuModel`.
- Narrow-width relayout is app-declared `AdwBreakpoint` setters, not
  automatic: "controls can be dynamically moved to a toolbar that is only
  shown at narrow widths."
  https://developer.gnome.org/hig/guidelines/adaptive.html

**So the GTK arm must synthesize the overflow itself.** The cheap version
costs kaya nothing new: the window's `gio::Menu` model already exists
(`core.menu_models[&window]`, gtk.rs:1272), so the end of the bar is
`GtkMenuButton::set_menu_model(that same model)` with
`open-menu-symbolic`. **[MEASURED]** probe4/A: a `GtkMenuButton` over a
`GMenuModel` whose items name `win.kmi-*` works unchanged.

---

## Q3 — is an 'extended' knob NEEDED to reach the genre look?

**No — and on this platform the knob would make things worse, because the
genre look is the CONSTRUCTOR DEFAULT and kaya is currently opted out of
it.**

The measurement that settles it. Two windows, same stylesheet
(`adw_init()` called in both), same two symbolic buttons plus a hamburger,
same scrolled content, screenshotted under Xvfb and read by mean gray
across x=100..400 **[MEASURED]** probe8:

| shape | rows 40-50 (the bar) | rows 51-56 (under it), at scroll 0 | scrolled |
|---|---|---|---|
| **kaya today** — `GtkApplicationWindow` + `set_titlebar(GtkHeaderBar)` | **255** (opaque, lighter than content) | **224, 241, 244, 247, 248, 249** — a persistent separator/shadow | *identical* |
| **GNOME shape** — `AdwApplicationWindow` + `AdwToolbarView` (FLAT default) + `AdwHeaderBar` | **250** (same as the content) | **250, 250, 250, 250, 250, 250** — nothing at all | **226, 242, 245, 248** — the shadow appears |

Read that as prose: **kaya's Linux chrome today is GNOME's RAISED
treatment — an opaque band with a permanent hairline under it. The modern
merged look is what you get by DEFAULT from `AdwToolbarView`, and kaya is
not using that container.** Both bars are 46px; nothing about height is
involved.

Screenshots: `out/x11-kaya-today-top.png` vs `out/x11-gnome-shape-top.png`
(the separator is visible to the eye in the first and absent in the
second); `out/x11-flat-top.png` vs `out/x11-flat-scrolled.png` for the
scroll-edge behaviour.

Three consequences for C1/C2 as drafted:

1. **docs/chrome-plan.md:49 has the polarity backwards.** It lists the GTK
   `extended` lowering as "`AdwToolbarView` with `top-bar-style = flat`".
   `flat` is the **default** — **[MEASURED]** the GParamSpec default of
   `AdwToolbarView:top-bar-style` is `0` and a fresh `Adw.ToolbarView()`
   reads `ADW_TOOLBAR_FLAT`. So a `chrome: standard | extended` prop would
   have to implement `standard` by **deliberately setting RAISED**, i.e.
   the knob's only Linux effect would be to let an app ask for the older
   look. That is a knob whose default value is the wrong one.
2. **The `.flat` style class is deprecated for exactly this reason.**
   **[DOC]** "The `.flat` style class can be used with an `AdwHeaderBar` or
   `GtkHeaderBar` to give it a flat appearance. **Use `AdwToolbarView`
   instead. Deprecated since: 1.4.**" GNOME moved the flat treatment from a
   style class you apply to a container you use. Modelling it as a kaya
   style knob re-creates the thing GNOME deprecated.
3. **The tall half is unreachable and there is nothing to reach it with.**
   **[MEASURED]** 46px in all four configurations (flat, raised, plain
   `set_titlebar`, with buttons packed). No `AdwToolbarStyle` member
   changes height; there is no size class; `GtkToolbar` is gone. **[DOC]**
   the HIG has no taller/expandable/multi-row header bar pattern.

The one genuinely "extended" API is
**`AdwToolbarView:extend-content-to-top-edge`** (gboolean, since 1.4,
**[MEASURED]** default `False`) — content drawn *under* a floating top bar.
That is C1's shape, not C2's, and C1 is deferred. **[MEASURED]** probe7: it
does not change the bar's height either; it changes where the content
starts and suppresses the undershoot.

**Verdict Q3: no knob. Landing C2 on `AdwToolbarView` gets the genre look
as a side effect of having a bar at all — the same "the toolbar IS the
tall-bar cause" story the plan tells for macOS's `.unified`, except on
Linux the effect is flat/merged rather than tall.**

---

## Q4 — can kaya reach it with ZERO new styling vocabulary?

**Yes. Everything needed is either an existing kaya construct or an
internal backend choice with no protocol surface.**

### What C2 needs on GTK, in full

1. **Container swap, invisible to every guest**:
   `gtk4::ApplicationWindow` → `adw::ApplicationWindow`, and the chrome
   moves from `set_titlebar(HeaderBar)` to
   `AdwApplicationWindow::set_content(AdwToolbarView)` with
   `add_top_bar(AdwHeaderBar)`.
   - **[MEASURED]** `AdwApplicationWindow` **is** a `GtkApplicationWindow`
     (`AdwApplicationWindow → GtkApplicationWindow → GtkWindow → GtkWidget`)
     and **is** a `GActionMap`, so gtk.rs:2380's downcast, `add_action`, and
     the whole `win.` prefix survive untouched (probe9/G, probe9/I: a button
     on `win.kmi-9` still tracks `set_enabled` inside an `AdwApplicationWindow`).
   - **[MEASURED]** it works under a plain `gtk4::Application` — no
     `adw::Application` needed (probe8 built one that way).
   - **[DOC]** `AdwToolbarView`, `AdwToolbarStyle`, `AdwHeaderBar::set_show_back_button`
     are all **`v1_4`** in the Rust crate — https://docs.rs/libadwaita/0.9.2/libadwaita/struct.ToolbarView.html
     says "Available on **crate feature `v1_4`** only", and `pack_start`/`pack_end`
     are ungated. **kaya's Cargo.toml does not move.**
2. **The promotion list** → `pack_start` per promoted item, in order, each
   button carrying `action-name = "win.kmi-<id>"`, `icon-name` from
   `symbol_icon_name(item.symbol)`, and an accessible label + tooltip from
   `item.label`.
3. **The overflow** → one `GtkMenuButton` packed at the end over the
   window's EXISTING `gio::Menu` model. No second model, no "remainder"
   concept, no new grammar: the primary menu is the whole catalog, which is
   what GNOME's hamburger is anyway.

### "Is there another styling construct we can sneak it into?"

Yes, and GNOME hands it over explicitly. **[DOC]** the `AdwToolbarStyle`
page: FLAT "suits simple content … and **windows with sidebars should
always use this style**." kaya already knows whether a window has a
sidebar — `sections_presentation` hint 2 and the `list_detail` window
prop both reach gtk.rs — so the FLAT-vs-RAISED decision is **derivable
from constructs kaya already has**, with nothing new declared. And since
FLAT is the default anyway, "derivable" collapses to "never set it":
the backend uses `AdwToolbarView` as constructed, and the one case where
GNOME would want RAISED (`AdwTabView`-style content with per-page
backgrounds) does not exist in kaya's vocabulary. **[INFER]** on that
last clause — it is an argument from kaya's current widget set, not a
measurement.

### Knobs that would be no-ops (or worse) on other platforms — the maintainer's elimination list

| candidate knob | verdict |
|---|---|
| `chrome: standard \| extended` (C1) | **No-op on Linux in the direction that matters.** `extended`'s stated GTK lowering (flat) is already the default; the knob's only Linux content is a way to ask for RAISED, which no app should want. Already deferred — keep it deferred, and delete the GTK row from the table rather than implementing it. |
| a `toolbar_style: flat \| raised` prop | **Refuse.** Pure GNOME vocabulary — nothing on mac, iOS, Android or WinUI corresponds. `AdwToolbarStyle` is a decision about the CONTENT ("windows with sidebars should always use FLAT" **[DOC]**), which the backend can make from what it already knows. |
| `title_hidden` (C1b) | Untouched by this report; GTK can express it (`AdwHeaderBar:show-title = false`, **[MEASURED]** default `True`) but it is C1's question. |
| a toolbar `height`/`size` knob | **Refuse — physically no-op on Linux.** **[MEASURED]** 46px under every configuration. It would be a mac-only knob wearing a cross-platform name. |
| an `overflow: menu \| clip` knob | **Refuse.** GTK has exactly one possible behaviour (the backend synthesizes a menu button, or the window stops shrinking). Nothing to choose. |
| a per-item `placement: start \| end` | Already refused in the draft ("per-item placement control beyond order"). Agreed from this side: GTK *could* express it (`pack_end`), but the end is where the platform puts the window controls and the primary menu, and an app packing there fights the shell. |

### The sectioned-sidebar / split-view question: who owns the bar?

**[DOC] + [MEASURED]** In `AdwNavigationSplitView`, **each `AdwNavigationPage`
owns its own header bar** — the idiom is one `AdwToolbarView` + `AdwHeaderBar`
per page, not one bar for the window. That is why the sidebar page and the
detail page can carry different titles and different actions, and why
`AdwHeaderBar:show-back-button` (**[MEASURED]** default `True`) can mint the
collapsed-mode back button in the detail page only.

kaya's current split arm gives the pages the **raw scene root** (gtk.rs:1602-1619),
so there is no page-owned bar and libadwaita mints nothing — **[MEASURED]**
probe5/D2. This is the single largest structural consequence of C2 on Linux:
**a window that both promotes toolbar items and uses list-detail has to decide
which page's bar the promotions land in.** The GNOME answer is the *detail*
page (the sidebar's bar carries the list's own title and, at most, a "new"
button), and the two bars then align into one visual band because both are
flat.

Adopting page-owned `AdwHeaderBar`s would also let gtk.rs **delete**
`install_nav_chrome`'s hand-built back button and the two
`idle_add_local_once` visibility handlers at gtk.rs:1651-1692 — libadwaita
does both (**[MEASURED]** probe5/D). That is a net simplification, not new
surface.

### The sections arm

Not required by C2, but it is the other place GTK's own component beats
kaya's: the `bar` presentation is a `GtkStackSwitcher` sitting in the window
CONTENT (gtk.rs:1842-1849), where GNOME puts an `AdwViewSwitcher` in the
header bar's title slot. gtk.rs:1873-1883 already records why the current
choice hurts — `GtkStackSwitcher` renders icon **or** title, never both,
where "libadwaita's AdwViewSwitcher is the component that shows both". Once
the backend owns an `AdwHeaderBar`, its title slot is the natural home for
that switcher. **[INFER]** on the visual result; the component swap is
`Adw::ViewSwitcher` + `Adw::ViewStack`, a rewrite of the sections lowering
rather than a line of it — a separate slice, and no protocol change either
way.

---

## The one-paragraph answer

On GTK 4.18.6 + libadwaita 1.7.6, an ordered promotion list lowers to
`AdwHeaderBar::pack_start` per item with `action-name = "win.kmi-<id>"`,
and there is **no tall/extended variant at any layer** — the bar is 46px in
every configuration measured, `GtkToolbar` is gone, and the HIG has no
multi-row or expandable header bar. What the plan calls the "modern look"
exists here as the FLAT top-bar treatment, and **it is the constructor
default of `AdwToolbarView`** (`ADW_TOOLBAR_FLAT = 0`), while the deprecated
`.flat` style class points apps at that container instead. kaya is currently
opted out of it by using `set_titlebar(GtkHeaderBar)`, which measures as
GNOME's RAISED look (opaque 255 band + permanent hairline) against the
GNOME shape's merged 250-on-250 with a scroll-only shadow. Enablement, flat
button styling, window dragging, the scroll-edge shadow and (in split view)
the collapsed-mode back button are all free; icon, label, **accessible
name** and **overflow** are not — and overflow especially, because GTK has
none and simply refuses to shrink the window (24 buttons → `min_width=1155`).
So: **no `extended` knob, no toolbar-style knob, no height knob. Swap the
container inside gtk.rs, pack the list, add one `GtkMenuButton` over the
GMenu model kaya already builds, and the genre look arrives as a side
effect with zero new styling vocabulary in the protocol.**

## Guard candidates this research suggests (invariant 3)

- **The blank accessible name.** An icon-only promoted button publishes
  `name=''` **[MEASURED]**, and the plan's own `expect_toolbar_item i
  "label"` would then compare against the empty string on GTK while every
  other platform reads a real name. A promotion lowering that forgets the
  a11y label is invisible to `check-universal-props.sh`'s current shape
  (that gate covers declared a11y props on widget kinds, not chrome). The
  wall wants to be on the path: the GTK promotion helper takes the label
  and writes both tooltip and `AccessibleProperty::Label`, with the
  gate reading the bus.
- **The unshrinkable window.** A promotion list long enough to raise the
  window's minimum width past the HIG's 1024px floor is a silent
  regression — nothing fails, the window just stops resizing.
  **[MEASURED]** ~48px per button, so ~21 buttons reaches 1024. A cheap
  debug-only assertion in the GTK arm ("this window's header bar asks for
  N px minimum") is the shape; a declare-time cap is the other.
- **The polarity trap in the plan.** If C1 is ever revived, the GTK row
  must not say `extended → flat`: whatever the backend does for
  `standard` is the thing that needs writing down, because flat is what
  it gets for free.

## Files

- Report: this file.
- Probes (read-only, outside the repo):
  `adw_probe.py` … `adw_probe9.py`, `adw_probe7.sh`/`8`/`9`,
  `a11y_app.py`, `a11y_read.py`, `a11y_run.sh`.
- Screenshots: `out/x11-*.png` (kaya-today vs gnome-shape, flat vs
  scrolled vs raised vs extended).

## Cleanup (per the standing side-effects rule)

- **No repo edits of any kind.** Everything here lives under
  `…/scratchpad/chrome/ (gone)`. (`git status` in the repo shows
  `M docs/deferred.md` — that is NOT from this agent; it was already
  moving when this work started and belongs to another arm of the run.)
- **Containers**: every `docker run` used `--rm`. One container
  (`50c89d509a2e`, `sh /probe/a11y_run.sh`) survived a host-side
  `timeout` that killed the docker CLI rather than the container; it was
  killed explicitly and `docker ps` and
  `docker ps -a --filter ancestor=kaya-linux:latest` are both **empty**.
- **Disk**: this arm's own artifacts are `out/` at **144K** plus ~40K of
  probe scripts and this report. Nothing was built; no cargo target, no
  image layers added.
