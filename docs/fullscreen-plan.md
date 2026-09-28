# Fullscreen — the design pass

Status: DESIGNED 2026-09-28; DEPTH BUILT 2026-09-28 (the spec, the core, the
Rust binding, the SwiftUI arm on macOS and iOS, the scene green on the mac
lane); breadth open (docs/deferred.md, "BUILD — fullscreen"). The roadmap's second piece for the
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

WHEN THE TWO CROSS, THE APP'S WRITE WINS (ruled 2026-09-28): an app write
that lands while the user's own transition is still animating is held, and
applied once it settles. A user change the app overrode before it settled
is not reported, so the app, the core's mirror and the window end on the
app's value; the occurrence fires only when the settled state is the
user's. An app write that agrees with the user's result is no override, and
the user's change is reported.

No command, no toggle verb in the API: an app that wants a toggle writes
`fullscreen(!on)` from the state it already holds.

## §2 — The user's door

| platform | the door | what kaya adds |
|---|---|---|
| macOS | the green button, ⌃⌘F, the Enter Full Screen item AppKit inserts into a menu titled View (DESIGN.md, menus) | `.fullScreenPrimary` on every window: a `.regular` app's resizable window has the door from AppKit, an `.accessory` one does not (§4.1, measured) |
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
| SwiftUI, macOS | `NSWindow.toggleFullScreen(nil)` when the style mask disagrees; a write during a transition is held and reconciled one main-queue turn after `didEnter`/`didExitFullScreen` or the delegate's `windowDidFailToEnter`/`ExitFullScreen` | the two notifications, minus the transitions kaya itself started |
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
   MEASURED 2026-09-28 (a plain NSWindow probe, `.accessory`, never
   activated, on the lane host with HIDIdleTime above 16,000 s):
   - Under `.accessory` with the default collectionBehavior,
     `toggleFullScreen` does nothing at all (no will, did or fail
     callback), and the green button ZOOMS the window instead. A
     `.regular` app gets the door with the same behavior; `.accessory`
     needs `.fullScreenPrimary` inserted, after which both the call and
     the green button work.
   - The style mask carries `.fullScreen` from the call itself;
     `didEnterFullScreen` follows about 580 ms later, and leaving takes
     about 550 ms. The window is 1728x1084 on a 1728x1117 screen.
   - Entering ACTIVATES the accessory app and makes the window key, and
     both stay after leaving: a fullscreen leg takes the host's keyboard
     as well as its display.
   - A toggle issued during or just after a transition fails: an exit
     followed 20 ms later by an enter posted didFailToExit, didExit,
     willEnter and didFailToEnter, and the window ended NOT fullscreen,
     neither write holding. A toggle issued one main-queue turn after
     `did*` succeeded every time (4 flips, 0 failures).
   - The WindowGroup's own window under `.accessory` carries
     `.fullScreenNone` and SwiftUI writes it back after every insert
     (measured on the fullscreen leg, docs/traps.md); under `.regular` it
     already has `.fullScreenPrimary`. The arm reopens the door at every
     accessor update and before every toggle and harness click.
2. **Linux x11 has no window manager.** GTK asks the window manager
   through `_NET_WM_STATE`; the lane's Xvfb runs none, so the request may
   do nothing there. Headless sway (the wayland slots) honours
   fullscreen with floating forced. If x11 cannot, the scene runs on the
   wayland slots only, recorded in the linux lane table.
   MEASURED 2026-09-28 in the linux image, the lane's own session shapes:
   on Xvfb with no window manager `gtk_window_fullscreen` does nothing
   (`is_fullscreen` false, no `notify::fullscreened`, the surface
   unchanged 1.5 s later); on headless sway `notify::fullscreened` fires
   about 1 ms after the call and the surface is the output's 1600x1000 a
   frame later, sway's tree reading fullscreen_mode 1. So the GTK legs
   run on the wayland slots only.
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
