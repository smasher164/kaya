# Linux/GTK4 app identity (icon + name), Wayland and X11

Every claim is marked: [DOC] cited and version-pinned, [MEASURED] I ran it
(command + output shown), [REPO] read out of this tree, [INFER] reasoning,
marked as such. Everything measured ran inside the lane's own image
(`kaya-linux:latest`, built from `tools/linux/Dockerfile`), never on the host,
and the repo was never modified.

---

## 0. What the tree pins, and what the lane actually runs

- [REPO] `crates/kaya/Cargo.toml:151` — `gtk4 = { version = "0.11.4", features = ["v4_10"] }`.
  The `v4_10` feature is the API level the Rust bindings compile: anything added
  after GTK 4.10 is invisible through the crate as configured even when the
  runtime library has it. (Relevant below: `gdk_wayland_toplevel_set_application_id`
  is old enough to be in; the Wayland icon path is a 4.20 runtime thing that
  needs no new crate API at all.)
- [REPO] `crates/kaya/Cargo.toml:175` — `adw = { package = "libadwaita", version = "0.9.2", features = ["v1_4"] }`.
- [MEASURED] versions inside the image
  (`docker run --rm kaya-linux:latest bash -lc 'pkg-config --modversion gtk4 libadwaita-1; dpkg -l | …'`):
  ```
  gtk4 4.18.6        libadwaita-1 1.7.6        glib 2.84.4
  libgtk-4-1 4.18.6+ds-2          adwaita-icon-theme 48.1-1
  sway 1.10.1-2      weston 14.0.2-1           xvfb 2:21.1.16-1.3
  wayland-protocols 1.44-1        (arm64, Debian trixie pinned by digest)
  ```
- [REPO] `crates/kaya/src/gtk.rs:7041` — the app is a real `GtkApplication`:
  `gtk4::Application::builder().application_id("dev.kaya.Milestone2").build()`,
  and the window (7056) is a `GtkApplicationWindow` titled `"kaya milestone 2"`.
  **No icon call exists anywhere in gtk.rs** — grepping `set_icon` finds only the
  semantic-symbol vocabulary (`GtkStackPage::set_icon_name`,
  `Button::from_icon_name`, docs/styling-plan.md D6), which is about widget
  glyphs, not window identity.
- [REPO] There is no `.desktop` file in the tree (`git ls-files "*.desktop"` is empty).
- [REPO] `tools/linux/run-suites.sh` runs **both** protocols for every leg:
  - x11 (line 319): `GDK_BACKEND=x11 … xvfb-run -a -s "-screen 0 1024x768x24"` —
    bare Xvfb, **no window manager** (the Dockerfile's xdotool note says so).
  - wayland (line 323): `GDK_BACKEND=wayland WAYLAND_DISPLAY=$KAYA_WAYLAND_SOCKET`
    against one session-wide **headless sway** (`WLR_BACKENDS=headless`, line 173).
    Weston was rejected for having no `wl_seat` headless.
- [REPO] `run-suites.sh:164` states "kaya's GTK windows carry
  application_id("dev.kaya.Milestone2"), so the app_id rule matches". **That
  reason is wrong** (the rule `app_id=".*"` matches anything, so the lane is
  unaffected) — see §4.3: GTK's Wayland `app_id` comes from the *prgname*, not
  from the GApplication id. The lane's legs therefore run under app_ids like
  `milestone2`, `python3`, `dotnet`, `java`, `kaya-go` — one per launcher binary
  (`run-suites.sh:459-502`). [MEASURED for the mechanism, [INFER] for each leg's
  exact string.]

---

## 1. GTK4's window-icon API: what is gone, what is left

[MEASURED] The GTK3 pixbuf call is gone from the headers and from the library:

```
$ grep -rn "set_icon\|icon_name" /usr/include/gtk-4.0/gtk/gtkwindow.h
165:void        gtk_window_set_icon_name         (GtkWindow *window, const char *name);
168:const char *gtk_window_get_icon_name         (GtkWindow *window);
170:void        gtk_window_set_default_icon_name  (const char *name);
172:const char *gtk_window_get_default_icon_name  (void);

$ nm -D --defined-only libgtk-4.so.1 | grep -iE "gtk_window.*icon"
gtk_window_get_default_icon_name   gtk_window_get_icon_name
gtk_window_set_default_icon_name   gtk_window_set_icon_name
```
No `gtk_window_set_icon`, no `set_icon_list`, no `set_icon_from_file`,
no `set_default_icon` — the four name-based calls are the entire `GtkWindow`
icon surface. `gtk_window_set_default_icon_name` **does** still exist in GTK4
(the question in the brief); there is no `gtk_application_set_default_icon_name`.

[DOC] `gtk_window_set_icon_name`, docs.gtk.org (GTK API 4.0, docs built from
4.23.3): "Sets the icon for the window from a named themed icon. See the docs
for GtkIconTheme for more details. **On some platforms, the window icon is not
used at all.** Note that this has nothing to do with the WM_ICON_NAME property
which is mentioned in the ICCCM."
<https://docs.gtk.org/gtk4/method.Window.set_icon_name.html>

[DOC] The 3→4 migration guide never mentions window icons; its only relevant
line is the general one, "A number of GdkPixbuf-based APIs have been removed.
The available replacements are either using GIcon, or the newly introduced
GdkTexture or GdkPaintable classes instead."
<https://docs.gtk.org/gtk4/migrating-3to4.html>

**So the public GtkWindow surface takes a NAME that must resolve through
GtkIconTheme.** But that is not the whole of GTK4 — see §3.2, which is the
finding that changes the design space.

---

## 2. Can a runtime PNG blob be made resolvable as an icon *name*? Yes — two ways

[MEASURED] (`iconprobe.c`, run under both backends; identical results):

```
PROBE initial search path   = /root/.local/share/icons : /root/.icons :
                              /usr/local/share/icons : /usr/share/icons :
                              /usr/local/share/pixmaps : /usr/share/pixmaps
PROBE initial resource path = /org/gtk/libgtk/icons/
PROBE A/before   has_icon(kaya-brand-unthemed)=FALSE lookup -> …/image-missing.svg
PROBE B added search path /tmp/kayaicons while the dir was EMPTY
PROBE B/empty        has_icon(kaya-brand-unthemed)=FALSE
PROBE B wrote both PNGs AFTER the path was added
PROBE B/after-write  has_icon(kaya-brand-unthemed)=FALSE   <-- the cache trap
PROBE B/after-write  has_icon(kaya-brand-hicolor )=FALSE
PROBE B/re-added     has_icon(kaya-brand-unthemed)=TRUE  -> file:///tmp/kayaicons/kaya-brand-unthemed.png
PROBE B/re-added     has_icon(kaya-brand-hicolor )=TRUE  -> file:///tmp/kayaicons/hicolor/64x64/apps/kaya-brand-hicolor.png
PROBE C registered a GResource built at runtime from 736 opaque bytes
PROBE C   resource child: /dev/kaya/icons/64x64/apps/kaya-brand-res.png
PROBE C/before-add   has_icon(kaya-brand-res)=FALSE
PROBE C/after-add    has_icon(kaya-brand-res)=TRUE -> resource:///dev/kaya/icons/64x64/apps/kaya-brand-res.png
```

### 2.1 Facts

1. **Files on disk + `gtk_icon_theme_add_search_path` works.** Both layouts
   resolve: a bare `<dir>/<name>.png` (unthemed) and a full
   `<dir>/hicolor/64x64/apps/<name>.png` with an `index.theme`.
2. **A GResource registered at runtime works, with no file on disk.**
   `g_resource_new_from_data(bytes)` + `g_resources_register` +
   `gtk_icon_theme_add_resource_path` makes `has_icon` true and the lookup
   returns a `resource://` URI. [MEASURED] Both resource layouts resolve — a
   sized dir (`/dev/kaya/icons/64x64/apps/x.png`) **and** a flat one
   (`/dev/kaya/icons/x.png`) — `resprobe.c`:
   `RES sized-dir has_icon(kaya-brand-res)=TRUE`, `RES flat-root has_icon(kaya-brand-flat)=TRUE`.
3. **CACHE TRAP [MEASURED].** The icon theme scans a path when it is added and
   does not notice files that appear afterwards within the same main-loop turn.
   Adding the path while the directory was empty and *then* writing the PNG left
   `has_icon` FALSE; re-adding the same path forced a rescan and it went TRUE.
   The same shape bit the resource case: registering the GResource *after* the
   path was already in the list left it FALSE until `add_resource_path` ran again.
   Rule: **land the bytes first, add the path second** (or add it twice).
4. **`g_resource_new_from_data` takes a GVDB blob, not a PNG** [DOC/INFER].
   My measurement fed it a `.gresource` produced by `glib-compile-resources`.
   glib exposes no public API to *build* a GResource in-process, so a PNG that
   arrives over kaya's wire cannot be handed to it directly. Two honest options:
   (a) write the blob to a private temp dir and use `add_search_path` — the same
   shape kaya already uses for the brand typeface, which writes the font bytes to
   a file and calls `pango_font_map_add_font_file` [REPO gtk.rs:6915-6979,
   7386 `.write_all(&bytes)`]; or (b) synthesize the GVDB container (the `gvdb`
   Rust crate does exactly this) [INFER — not measured here].
   Given (a) is already the tree's precedent for blob-shaped resources, it is the
   cheaper answer, and §3.2 makes even that unnecessary.
5. **An unresolvable name fails silently** [MEASURED]:
   `RES set_icon_name to an ABSENT name: no error, echo = kaya-brand-nope`.
   Same silent-fallback hazard the tree already documents for symbol icons
   (gtk.rs:145-193).

---

## 3. X11 — what actually lands on the window

### 3.1 The name path works *only* if the icon has declared SIZES

[MEASURED] (`pixprobe.c`, X11 under bare Xvfb, GTK 4.18.6, reading the window's
own property with `xprop -id <xid> _NET_WM_ICON`):

| mode | icon injected as | `get_icon_sizes` | `_NET_WM_ICON` |
|---|---|---|---|
| `name-flat` | `/tmp/pixicons/kaya-flat.png` (unthemed, in a search path) | `[]` | **not found** |
| `name-themed` | `/tmp/pixicons/hicolor/64x64/apps/kaya-themed.png` + index.theme | `[64]` | **`Icon (64 x 64)`** |
| `name-stock` | `text-editor` (not in this image's theme) | `[]` | not found |
| `direct` | no name at all, see §3.2 | — | **`Icon (64 x 64)`** |
| `noicon` | nothing | — | not found |

The mechanism, from the source [DOC, GTK 4.18.6 `gtk/gtkwindow.c`]:
`gtk_window_realize_icon()` (line 3393) calls `icon_list_from_theme()` (3344),
which iterates `gtk_icon_theme_get_icon_sizes(theme, name)` and renders each size
to a `GdkTexture`, then calls `gdk_toplevel_set_icon_list()` (3427). If the sizes
array is empty the list is NULL, and `gdk_x11_surface_set_icon_list` with an
empty list does `XDeleteProperty(_NET_WM_ICON)` [DOC, `gdk/x11/gdksurface-x11.c:3273-3278`].

So **`has_icon()` returning TRUE is not enough** — a flat unthemed PNG resolves
for a `GtkImage` and still produces no window icon, with no error anywhere. The
blob must be laid out in a themed directory whose name declares a size
(`<theme>/64x64/apps/<name>.png` + `index.theme`), or in the equivalent
resource layout.

[MEASURED] Normal installed icons do have sizes, so this is not an argument that
the name path is useless: `image-missing sizes=[-1,16]`, `folder sizes=[-1,16]`,
`go-home-symbolic sizes=[-1]` (`-1` = scalable, which GtkWindow renders at 48px
[DOC gtkwindow.c:3366-3375]).

### 3.2 The finding that changes the design: `gdk_toplevel_set_icon_list` is PUBLIC

[MEASURED] It is in the public header and exported:
```
$ grep -rn icon /usr/include/gtk-4.0/gdk/gdktoplevel.h
184:void gdk_toplevel_set_icon_list (GdkToplevel *toplevel, GList *surfaces);
$ nm -D --defined-only libgtk-4.so.1 | grep -oE "gdk_[a-z0-9_]*icon[a-z0-9_]*"
gdk_app_launch_context_set_icon   gdk_app_launch_context_set_icon_name   gdk_toplevel_set_icon_list
```
[DOC] `gdk/gdktoplevel.c` 4.18.6: "`@surfaces: (element-type GdkTexture)` A list
of textures to use as icon, of different sizes. Sets a list of icons for the
surface. One of these will be used to represent the surface in iconic form."
The `GdkToplevel` interface also carries it as a writable `icon-list` property
[MEASURED — enumerating the live surface's properties printed
`prop: icon-list type=gpointer flags=RW`].

[MEASURED] Blob → texture → property, no theme and no name involved:
```
PIX blob = 226 bytes of PNG
PIX decoded texture 64x64                (gdk_texture_new_from_bytes)
PIX surface at set time = GdkX11Toplevel (gdk_toplevel_set_icon_list after present)
PIX xprop _NET_WM_ICON: _NET_WM_ICON(CARDINAL) = 	Icon (64 x 64):
```
That is **real pixel data from a runtime blob on the X11 window**, in three calls,
with nothing on disk and nothing in the icon theme. Caveat [DOC/INFER]:
`gtk_window_realize_icon` runs once at realize and would overwrite it, so the
call must come after the window is realized/presented, and again after any
unrealize (`gtk_window_unrealize_icon`, gtkwindow.c:3461).

### 3.3 The tidy route, end to end

[MEASURED] (`appicon2.c`) Registering the blob's GResource **before**
`g_application_run`, at `<resource_base_path>/icons/64x64/apps/<app-id>.png`:
```
APPICON2 registered 555 bytes BEFORE g_application_run
APPICON2 default icon name after startup = dev.kaya.Milestone2
APPICON2 has_icon(dev.kaya.Milestone2)=1
APPICON2 sizes=[64]
APPICON2 _NET_WM_ICON: _NET_WM_ICON(CARDINAL) = 	Icon (64 x 64):
```
Two GTK behaviours make this work, both confirmed in source and measured:
- [DOC] GtkApplication class docs: "GtkApplication will also automatically setup
  an icon search path for the default icon theme by appending "icons" to the
  resource base path" and "GtkApplication will also automatically set the
  application id as the default window icon."
  [MEASURED] inside `activate`: `resource path = /org/gtk/libgtk/icons/ : /dev/kaya/Milestone2/icons/`,
  `resource base path = /dev/kaya/Milestone2`.
- [DOC] `gtk/gtkapplication.c:263-279` (4.18.6) — the auto default icon is
  conditional: it returns early if a default icon name is already set, **and it
  requires `gtk_icon_theme_has_icon(theme, appid)` at startup time**.
  [MEASURED] Registering the same resource inside `activate` (i.e. after startup)
  left `gtk_window_get_default_icon_name() = (null)` and `has_icon = 0`, and no
  `_NET_WM_ICON`. Ordering is load-bearing; alternatively the app can just call
  `gtk_window_set_default_icon_name(appid)` itself after injecting.

### 3.4 What identity else lands on X11 [MEASURED]

For a real GtkApplication + GtkApplicationWindow (`appprobe.c`):
```
WM_CLASS(STRING) = "kaya-guest-demo", "kaya-guest-demo"   <-- from prgname (argv[0]), NOT the app id
_NET_WM_NAME(UTF8_STRING) = "kaya milestone 2"            <-- the window title
WM_ICON_NAME / _NET_WM_ICON_NAME = "kaya milestone 2"     <-- the ICONIFIED TITLE, not an icon
_GTK_APPLICATION_ID(UTF8_STRING) = "dev.kaya.Milestone2"  <-- GTK's own property, X11 only
_NET_WM_PID = 228, WM_CLIENT_LEADER, _GTK_WINDOW_OBJECT_PATH, …
```
`WM_CLASS` is what a taskbar matches against `StartupWMClass` (§5), and it is the
binary's name, not the app id. Note that `_NET_WM_ICON_NAME` has nothing to do
with icons — the GTK docs call this out explicitly (§1).

---

## 4. Wayland — the honest part

### 4.1 On the lane's GTK (4.18.6), the Wayland backend ignores icons entirely

[DOC, GTK 4.18.6 `gdk/wayland/gdktoplevel-wayland.c:1318`] the property setter is
literally:
```c
    case LAST_PROP + GDK_TOPLEVEL_PROP_ICON_LIST:
      break;                       /* set: no-op */
    …
    case LAST_PROP + GDK_TOPLEVEL_PROP_ICON_LIST:
      g_value_set_pointer (value, NULL);   /* get: always NULL */
```
[MEASURED] `pixprobe direct` and `pixprobe name-themed` under headless sway both
run clean and change nothing observable; `GdkWaylandToplevel` exposes no icon
state to read back. There is no Wayland equivalent of `xprop` here because there
is no property — the client simply never sends anything.

### 4.2 GTK 4.20 implements xdg-toplevel-icon-v1; 4.18 does not

- [MEASURED] `strings libgtk-4.so.1 | grep -i toplevel.icon` → nothing on 4.18.6.
- [DOC] GTK `NEWS`, "Overview of Changes in **4.19.0, 06-04-2025**":
  "Use the xdg_toplevel_icon protocol for window icons" and
  "#7397 [feature] implement `xdg-toplevel-icon-v1` (Matthias Clasen)".
  4.19.x is the unstable series for **4.20.0, released 29-08-2025** [DOC, NEWS
  header]. So: **GTK ≥ 4.20 ships it; GTK 4.18.6 (this lane) does not.**
- [DOC] GTK `main` `gdk/wayland/gdktoplevel-wayland.c:1401-1431` — the
  implementation takes the **same `GdkToplevel` icon-list of textures** and sends
  **wl_shm buffers**: `xdg_toplevel_icon_manager_v1_create_icon` →
  `xdg_toplevel_icon_v1_add_buffer(icon, buffer, 1)` per texture →
  `xdg_toplevel_icon_manager_v1_set_icon`. It does **not** use the protocol's
  `set_name` request. GtkWindow's path into it is unchanged (`gtkwindow.c:3508`
  in main still calls `gdk_toplevel_set_icon_list` after resolving the name
  through the theme).
  **Consequence [INFER, from those two source facts]: on GTK ≥ 4.20 a runtime
  blob CAN reach the compositor as pixels — via exactly the same
  `gdk_toplevel_set_icon_list(textures)` call that works on X11 today — provided
  the compositor binds the manager.**
- [DOC] The protocol is **staging**, `xdg_toplevel_icon_manager_v1` version 1,
  requests `create_icon` / `set_icon`, and `xdg_toplevel_icon_v1` with
  `set_name` (an XDG icon-theme name) and `add_buffer` (wl_shm, square).
  <https://wayland.app/protocols/xdg-toplevel-icon-v1>;
  [MEASURED] the image ships the XML at
  `/usr/share/wayland-protocols/staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml`
  (wayland-protocols **1.44**), 205 lines, whose own summary is "This protocol
  allows clients to set icons for their toplevel surfaces either via the XDG icon
  stock (using an icon name) …".
- [MEASURED] **The lane's compositor does not implement it.** Full global list
  from `wayland-info` against headless **sway 1.10.1**: 53 globals, no
  `xdg_toplevel_icon_manager_v1`, nothing matching `icon`. (`xdg_wm_base` v5,
  `wl_seat` v9, `zwlr_data_control_manager_v1` v2, …) Sway gained it later with
  wlroots 0.19 / sway 1.11+ [DOC, imprecise — wayland.app lists Sway among 19
  supporting compositors, incl. KWin, Mutter, Muffin, Hyprland, niri, labwc,
  Weston; I did not pin sway's exact version].

### 4.3 The app_id, and where it comes from

[MEASURED] `app_id` follows **`g_get_prgname()`**, i.e. argv[0]'s basename — the
same binary run under three names, reported by `swaymsg -t get_tree`:
```
--- argv[0] = appprobe ---            sway app_id='appprobe'
--- argv[0] = dev.kaya.Milestone2 --- sway app_id='dev.kaya.Milestone2'
--- argv[0] = kaya-guest-rust ---     sway app_id='kaya-guest-rust'
```
and with no GApplication at all (plain `gtk_init`), prgname is NULL and GDK's
fallback string is used: `sway app_id='GTK Application'` [MEASURED].
The GApplication's `application_id` does **not** set it.

[MEASURED] It is settable at runtime, per toplevel, through public API:
```
/usr/include/gtk-4.0/gdk/wayland/gdkwaylandtoplevel.h:67:
  void gdk_wayland_toplevel_set_application_id (GdkToplevel *toplevel, const char *application_id);

APPID called gdk_wayland_toplevel_set_application_id(dev.kaya.Brand) — prgname is still (null)
  sway app_id='dev.kaya.Brand' name='appid probe'
```
So the *name* half of identity is genuinely runtime-settable on Wayland, and it
is the string the whole desktop keys off. `g_set_prgname()` before display open
is the other spelling.

### 4.4 What the compositor does with app_id

[DOC] On Wayland a client has no `WM_CLASS`; xdg-shell's `set_app_id` is the
identifier, and desktops match it against `<app_id>.desktop` to obtain the icon
and display name. GNOME's own guidance and the long tail of bug reports say the
same thing: "the app_id … should match the .desktop file for the app (the first
part of the name, before .desktop)"; Mozilla shipped a bug titled "KDE Wayland:
`<appid>.desktop` must match `g_set_prgname(<appid>)`, otherwise windows have a
wayland icon". Sources:
<https://nicolasfella.de/posts/importance-of-desktop-file-mapping/>,
<https://gitlab.gnome.org/World/gedit/gedit/-/work_items/486>,
<https://bugzilla.mozilla.org/show_bug.cgi?id=1826330>.
[MEASURED, negative] Dropping a matching
`/usr/share/applications/dev.kaya.Milestone2.desktop` (with `Icon=` and
`StartupWMClass=`) changed nothing observable under headless sway — sway reports
app_id and renders no titlebar icon in this configuration, so the lane cannot
see the mapping happen even when it would.

---

## 5. The .desktop file: what it owns, and the packaging boundary

- [DOC] Desktop Entry Spec, `Icon` key: "If the name is an absolute path, the
  given file will be used. If the name is not an absolute path, the algorithm
  described in the Icon Theme Specification will be used to locate the icon."
  `StartupWMClass`: "If specified, it is known that the application will map at
  least one window with the given string as its WM class or WM name hint."
  <http://specifications.freedesktop.org/desktop-entry/latest/recognized-keys.html>
- It owns: the launcher entry (name, icon, categories, MIME handling); the
  identity the shell shows for a running window under Wayland (via app_id) and
  under X11 (via WM_CLASS/StartupWMClass); and, on GNOME, the app name in the top
  bar and in the app switcher. [DOC, per the matching sources in §4.4.]
- **It is packaging, and a runtime blob cannot reach it.** [INFER, forced by two
  facts:] the file must exist on disk in `XDG_DATA_DIRS/applications` *before*
  the shell matches a window, and its `Icon=` is resolved by the *shell's*
  process through the icon theme, not by the app's. An app could write a
  `.desktop` into `~/.local/share/applications` at runtime and re-run
  `update-desktop-database`, but that is installing software from inside a
  process, not declaring identity, and it would still race the first window map.
- The precise boundary: **`.desktop` is where identity lives for anything OUTSIDE
  the process** (launcher, dock, switcher, GNOME top bar). The process can only
  influence which `.desktop` it is matched to (app_id / WM_CLASS) and, where a
  protocol exists for it, hand over per-window pixels (X11 `_NET_WM_ICON` always;
  Wayland only via xdg-toplevel-icon-v1 on GTK ≥ 4.20 + a compositor that binds it).

### The NAME half specifically

Runtime-settable, and where each one shows [MEASURED unless noted]:

| call | reaches | visible where |
|---|---|---|
| `gtk_window_set_title` | `_NET_WM_NAME`/`WM_NAME` (X11), `xdg_toplevel.set_title` (Wayland: `sway node name='kaya milestone 2'`) | titlebar, window lists |
| `g_set_prgname` / `gdk_wayland_toplevel_set_application_id` | X11 `WM_CLASS`; Wayland `app_id` | which .desktop the shell matches → its `Name=` and `Icon=` |
| `g_set_application_name` | AT-SPI `Description` (§6); GTK uses it for some default titles | **not** the top bar, **not** WM_CLASS, **not** app_id |
| `.desktop` `Name=` | the shell | app switcher, top bar, launcher — [INFER] not settable at runtime |

So the identity *string* an app declares at runtime lands in the title and in the
app_id; the shell's own label for the app comes from the `.desktop` `Name=` it
matched. There is no runtime call that renames the GNOME top-bar entry.

---

## 6. What a harness can honestly READ on Linux

### 6.1 AT-SPI gives three identity strings — but no icon

[DOC, GTK 4.18.6 `gtk/a11y/gtkatspiroot.c:384-397`] the application accessible's
properties are hard-wired:
```c
"Name"         -> g_get_prgname () ? : "Unnamed"
"Description"  -> g_get_application_name () ? : "No description"
"AccessibleId" -> g_application_get_application_id (g_application_get_default ())
```
[MEASURED] against a live GtkApplication (`g_set_application_name("Kaya Brand
Name")`, app id `dev.kaya.Milestone2`, binary `kaya-guest-hold`), read with the
lane's own AT-SPI stack (`GTK_A11Y=atspi` + dbus-launch + at-spi-bus-launcher,
the shape of `tools/linux/a11y-leg.sh`):
```
  ATSPI Name         = 'kaya-guest-hold'       (GTK: g_get_prgname)
  ATSPI Description  = 'Kaya Brand Name'       (GTK: g_get_application_name)
  ATSPI AccessibleId = 'dev.kaya.Milestone2'   (GTK: application id)
  ATSPI window       = 'kaya milestone 2' role=frame
```
[MEASURED] The frame exposes `['Accessible', 'Action', 'Component']` and **no
Image interface** (`w.get_image_iface()` → False); the application exposes only
`['Accessible']` and attributes `{'toolkit': 'GTK'}`. **AT-SPI cannot read a
window icon at all** — there is nothing icon-shaped in the tree.
[MEASURED, negative control] With plain `gtk_init` and no GApplication, prgname
is NULL and AT-SPI reports `Name='Unnamed'` even though
`g_set_application_name` had been called — confirming Name is prgname and not the
application name.

### 6.2 X11 gives a real pixel read

`xprop -id <xid> _NET_WM_ICON` decodes the property as `Icon (64 x 64):` followed
by the cardinals [MEASURED, §3.1/§3.2] — that is the app's own bytes read back
out of the server, not an echo of a GTK field. `x11-utils` (xprop) is already in
the lane image [REPO Dockerfile:32], and the X11 legs each own an Xvfb, so a
by-hand read is available with no new dependency. Getting the *xid* from outside
the process needs a search (`xwininfo -root -tree`, or match on `_NET_WM_PID`),
since the lane runs no window manager. [INFER]

Contrast: `gtk_window_get_icon_name()` is a pure echo of the string just set
[DOC gtkwindow.c:3615-3623 returns `info->icon_name`] and proves nothing.

### 6.3 Wayland gives a name read, not a pixel read

`swaymsg -t get_tree` reports `app_id` and `name` per node [MEASURED throughout],
so the lane can assert the identity *name* under Wayland today. There is no
compositor-side icon to read on sway 1.10.1, and even with a compositor that
implements xdg-toplevel-icon-v1 the client's buffers are not exposed back to any
client — a read would have to be a screenshot of a shell surface that draws the
icon, which headless sway does not draw. [MEASURED + INFER]

---

## 7. Verdict

**Under X11 a runtime blob buys real, visible, readable pixels — today, on the
lane's exact GTK.** `gdk_toplevel_set_icon_list()` is public API in GTK 4.18.6,
takes `GdkTexture`s, and writes `_NET_WM_ICON` with the app's own bytes; I
measured `Icon (64 x 64)` on the window from a 226-byte PNG that never touched
the filesystem or the icon theme. The name-based route also works, but only if
the blob is injected into the theme in a *sized* layout — an unthemed PNG makes
`has_icon()` true and still produces no window icon, silently. The tidiest
version of the name route (blob → runtime GResource at
`<resource_base_path>/icons/64x64/apps/<app-id>.png`, registered before
`g_application_run`, picked up by GtkApplication's automatic default window icon)
I measured end to end and it lands `_NET_WM_ICON` too. Whether anything *shows*
it is the WM's business, and the lane runs no WM — so on the lane, X11 identity
is assertable (xprop) but not visible.

**Under Wayland, on this lane, a runtime blob buys nothing at all.** GTK 4.18.6's
Wayland backend answers `GDK_TOPLEVEL_PROP_ICON_LIST` with `break;` — the icon
never leaves the process — and headless sway 1.10.1 advertises no
`xdg_toplevel_icon_manager_v1` to send it to. The icon a Wayland desktop shows
for a kaya window is the one in the `.desktop` file its `app_id` matched, and
that file is packaging: on disk, ahead of time, out of a runtime blob's reach.
So the blunt answer the brief asks for is **yes, for GTK 4.18: on Wayland the
icon is the .desktop file's, and a runtime blob buys nothing visible.**

**That answer has a shelf life, and the fix is already upstream.** GTK 4.20
(29-08-2025) implements xdg-toplevel-icon-v1 by feeding *the very same*
`gdk_toplevel_set_icon_list(textures)` into `xdg_toplevel_icon_v1.add_buffer`.
One declared identity lowered as "decode the blob to textures and hand them to
the toplevel" is therefore protocol-agnostic by construction: it is pixels on
X11 now, and pixels on Wayland the day the lane's GTK and compositor move
(Debian trixie's 4.18.6 → any 4.20+, sway 1.10.1 → 1.11+). Nothing in the design
has to be conditional except the *expectation* of visibility.

**The name half is settable on both protocols and is worth doing regardless.**
`gdk_wayland_toplevel_set_application_id()` (public, measured working:
`sway app_id='dev.kaya.Brand'`) and `g_set_prgname` are the only levers that
decide which `.desktop` the desktop matches, and today kaya sets neither — every
lane leg advertises its launcher binary's name (`python3`, `dotnet`, `java`,
`milestone2`, `kaya-go`), which no `.desktop` will ever match, and which also
makes `run-suites.sh:164`'s comment about `application_id` inaccurate.

**For the harness:** the readable identity on Linux is (a) the AT-SPI triple —
`Name` = prgname, `Description` = `g_set_application_name`, `AccessibleId` =
application id — which is a genuine cross-process read of the NAME half through
the same stack the a11y legs already stand up; (b) `_NET_WM_ICON` via xprop on
the X11 legs, which is a genuine read of the ICON half's pixels; and (c)
`swaymsg -t get_tree` for `app_id`/title on the Wayland legs. There is no icon
read available under Wayland on this lane, and AT-SPI has no icon surface at all
(no Image interface on the frame) — so an icon assertion on Linux is
X11-only, and it must be stated that way rather than skipped quietly.

---

## Appendix: cleanup and artifacts

- [MEASURED] All six probe containers ran `--rm`; after the last one
  `docker ps -a` is empty and
  `docker ps -a --filter name=kaya-identity --format '{{.Names}}' | wc -l` = 0.
  Host process check `ps -Ao pid,etime,pcpu,command | grep -Ei "sway|xvfb|iconprobe|pixprobe|appprobe|kaya-identity"`
  → none. Every sway/Xvfb I started lived and died inside a container.
- No image was built; `kaya-linux:latest` was reused as it stood, so docker disk
  usage is unchanged.
- Files written: this report plus small probe sources
  (`iconprobe.c`, `appprobe.c`, `resprobe.c`, `pixprobe.c`, `appid.c`,
  `appicon.c`, `appicon2.c`, `nameprobe.c`, `run-probe{,2,3,4,5,6}.sh`) — 180 KB
  total, measured. The GTK reference sources downloaded for line-accurate
  citation (1.2 MB) were deleted after the citations above were taken; the
  deletion is measured (`rm` then `ls`). The enclosing
  `scratchpad/chrome/` directory is 110 MB, all of it from earlier sessions
  (files dated 16-17 Aug), not this task.
- The repo was not modified. NOTE, unrelated to this task: `git status` went from
  clean to ~10 modified files (bindings/csharp, bindings/python, bindings/swift,
  docs/tpl-props-plan.md, guests/…) during this session — another agent is
  working in the tree; none of those paths were touched by me.
