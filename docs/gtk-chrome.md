# GTK window controls: the desktop's, with a fallback (2026-09-15)

The maintainer's question (2026-09-14): the minimize, maximize and close
buttons in the linux lane's captures look ugly — three grey circles, the
minimize glyph sitting on its baseline like an underscore.

## What the lane shows, and what a desktop shows

GTK4 draws a window's own frame (client-side decoration). The buttons it
shows come from the session's `gtk-decoration-layout` setting and the
glyphs from the session's icon theme. A session with no settings — the
lane's Xvfb, a bare window manager, a container — gets GTK's compiled-in
layout, `menu:minimize,maximize,close`, in Adwaita's round buttons. A
GNOME session says `appmenu:close`: one close button, minimize and
maximize hidden by the desktop's choice. KDE supplies KWin's own frame on
X11 and Breeze's icons on Wayland; other desktops their own. A native app
follows the desktop; supplying a kaya-standard decoration over the
desktop's choice is what Electron does and what GNOME's guidelines argue
against.

## The rule as built (crates/kaya/src/gtk.rs `window_controls_plan`)

1. **Follow the desktop.** A session's layout and icon theme are taken as
   GTK reads them; kaya sets nothing over them.
2. **Fallback A.** A session that supplied nothing — GTK answers its
   compiled-in layout — takes GNOME's `appmenu:close`. A session whose
   own setting is byte-identical to GTK's default cannot be told apart
   and is treated as none; nothing is lost, since that is the string it
   would have shown.
3. **Flat C.** Any effective layout that shows minimize or maximize wears
   kaya's flat rules on the buttons — no circle at rest, a soft square on
   hover, red on close — on a provider at APPLICATION priority beside the
   brand's, so the user's own `gtk.css` still wins. The glyphs stay the
   session's: shipping kaya's would need an app-wide icon theme, which
   stops following the desktop. Under Adwaita the minimize bar is nudged
   to the centre (`-gtk-icon-transform`), the one glyph drawn on its
   baseline; other themes' glyphs are left where they are.
4. **Re-evaluated** when the session's layout or icon theme changes
   (GtkSettings notify), so a desktop switch mid-run is followed.

Two mechanism facts, measured while iterating: a GtkImage takes its
glyph from the icon theme and ignores a CSS `-gtk-icon-source`, and
libadwaita draws the circle on `windowcontrols > button > image`, not on
the button — the flat rules target the image node.

## Guards

`gtk::chrome_tests` holds the plan (no settings → GNOME's layout and no
CSS; a session's layout followed; three buttons → the flat rules; the
nudge only under Adwaita); tools/check-gtk.py compiles the arm. No scene
can see the chrome, so the review page carries a viewed capture of each
case, taken with `tools/linux/shot-gtk.py`.

## Photographing the chrome (the capture recipe)

`tools/linux/shot-gtk.py <scene> <out.png> [--layout <gtk-decoration-layout>] [--hold-after <n>]`
runs the scene's rust example in the lane's own container under Xvfb with
the scene's steps held by a settle, injecting a GTK settings file through
`XDG_CONFIG_HOME` when `--layout` is given (`appmenu:close` for GNOME's
look, `icon:minimize,maximize,close` for a three-button desktop), shoots
the root window and crops to the kaya window. Without `--layout` the
capture shows kaya's own fallback.

Landed as 187db95a; the matrix on that tree ALL PASS on all five lanes,
1,801 legs, in 1180s.
