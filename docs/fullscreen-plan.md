# Fullscreen — the design pass

Status: DESIGNED 2026-09-28, not built. The roadmap's second piece for the
video editor (its program monitor) and a piece of the media player and
photo gallery archetypes. Every choice below is RECOMMENDED; §8 names the
two a maintainer may want to overturn, and neither blocks the build.

## §1 — The surface

A window property, `fullscreen` (spec.rs WINDOW_PROPS 11, Bool, false
unless set), on any window: the app states whether the window fills its
screen, as it states `dirty` or `appearance`. It is mutable at any time
and takes effect as soon as the platform allows (a macOS transition that
is already animating finishes first; §3).

The user can also change it, through the platform's own door (§2). That
change reaches the app as an occurrence, `fullscreen_changed { window;
Bool on }`, the id-and-one-value family `notification_replied` introduced.
It is post-fact and user-only, which is `section_selected`'s rule: the
window has already changed, the core's mirror has moved with it, and an
app's own write never echoes.

No command, no toggle verb in the API: an app that wants a toggle writes
`fullscreen(!on)` from the state it already holds.

## §2 — The user's door

| platform | the door | what kaya adds |
|---|---|---|
| macOS | the green button, ⌃⌘F, the Enter Full Screen item AppKit inserts into a menu titled View (DESIGN.md, menus) | nothing: every SwiftUI window already has it |
| GTK | none in the toolkit; GNOME apps bind F11 themselves (Loupe, Totem, Web) | **F11 toggles**, as dress |
| WinUI | none in the toolkit; Windows apps bind F11 (Edge, Photos, Media Player) | **F11 toggles**, as dress |
| iOS, Android | none that leaves: Android's swiped-in bars are transient and re-hide | nothing; the occurrence never fires |

F11 is dress in DESIGN.md's sense: the backend supplies it, it is not in
the app's catalog, and an app shortcut on F11 wins (the app's own
declaration is the more specific statement). Escape is NOT added: an app's
Escape already means cancel, clear-search or dismiss, and the platforms
that leave fullscreen on Escape (a video player's) do it in the app.

## §3 — The lowerings

| backend | apply | observe the user |
|---|---|---|
| SwiftUI, macOS | `NSWindow.toggleFullScreen(nil)` when the style mask disagrees; a write during a transition is held and reconciled on `didEnter`/`didExitFullScreen` | the two notifications, minus the transitions kaya itself started |
| SwiftUI, iOS | `.statusBarHidden(on)` and `.persistentSystemOverlays(on ? .hidden : .automatic)` on the root | none |
| GTK | `gtk_window_fullscreen` / `unfullscreen` | `notify::fullscreened`, minus kaya's own |
| WinUI | `AppWindow.SetPresenter(FullScreen / Overlapped)` | `AppWindow.Changed` with `DidPresenterChange`, minus kaya's own |
| Compose | `WindowInsetsControllerCompat.hide(systemBars())` with `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`; `show` to leave | none |

On a phone, fullscreen is the platform's immersive mode: the status bar
and the navigation bar (Android) or home indicator (iOS) go away, which is
what a video player or photo viewer does there. The phone's window
already fills the screen, so this is the only reading that does anything.

The desktops' window memory (docs/tasks-s4-plan.md P4) records no frame
while a window is fullscreen: the frame to remember is the one the user
will get back. Fullscreen itself is not remembered across launches; an app
that wants that keeps it in `prefs()`.

## §4 — What is measured first

1. **The mac lane moves the host's display.** Entering fullscreen gives
   the window its own Space and switches the display to it. On the lane
   host that is the maintainer's screen, so the mac legs join the
   `EXCLUSIVE` set behind the HID-idle wait, and the measurement is when
   an `.accessory` app's window can go fullscreen at all, and how long
   the transition takes.
2. **Linux x11 has no window manager.** GTK asks the window manager
   through `_NET_WM_STATE`; the lane's Xvfb runs none, so the request may
   do nothing there. Headless sway (the wayland slots) honours
   fullscreen with floating forced. If x11 cannot, the scene runs on the
   wayland slots only, recorded in the linux lane table.
3. **Windows**: `FullScreenPresenter` under the lane's session, and
   what `Changed` reports for kaya's own `SetPresenter`.
4. **The phones' readbacks**: iOS's `statusBarManager.isStatusBarHidden`
   on the window scene; Android's `getRootWindowInsets().isVisible(systemBars())`.

## §5 — How a leg sees it

`tools/scenes/fullscreen.steps`, one guest per language: a button writes
`fullscreen(true)`; `expect_fullscreen on` reads the toolkit back (never
the prop, check-appearance's read-back rule), and a label proves no
occurrence echoed. Then `user_fullscreen off` drives the platform's own
door (§2: the green button's selector on macOS, F11 through the key path
`press` uses on GTK and WinUI) and the label shows the occurrence with
`off`. The phone lanes drop the user half through their lane tables,
since there is no door to drive.

New verbs: `expect_fullscreen on|off`, `user_fullscreen on|off`, in all
three harnesses.

## §6 — Bindings

The prop is a window prop, so its setter is generated in all nine and its
sugar spelling is held by check-sugar-surface's window-prop census. The
handler rides where each binding registers `section_selected`'s (a
window-level registrar), in all nine; the C floor reads the occurrence.

## §7 — Guards

- Core unit tests: a user change moves the mirror; a user change to a
  window that does not exist fails loudly (the `user_selected_section`
  stance).
- The scene: an app write that echoed shows in the label.
- check-verbs: both verbs and the constants in both interpreters.
- check-sugar-surface: the prop and the handler in nine.
- check-window-memory: the mac save skips a fullscreen frame; the GTK and
  WinUI unit tests hold the same.

## §8 — The two choices a maintainer may overturn

1. **F11 as dress on GTK and WinUI.** The alternative is no door at all
   there, and an app that forgets to bind one strands its user in a
   window with no title bar.
2. **Immersive mode on the phones.** The alternative is an inert prop on
   the phones, which leaves a media player there unable to hide the bars.
