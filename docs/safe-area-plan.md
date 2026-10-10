# Safe areas and the keyboard: the design pass (2026-10-09)

Status: RECOMMENDED 2026-10-09, A1-A16 awaiting the maintainer; nothing
built. He picked "safe-area and keyboard avoidance on phones" from the
2026-10-09 shortlist. Its roadmap card (docs/roadmap/features.toml,
`safe_area`) gives the shape as "scene proof + a scroll behaviour" and says
what is owed: a scene with an entry at the bottom proving it stays visible
with the keyboard up, on both phones. §0 found that the owed proof would
fail today on Android for any field outside a scroll and for every field in
landscape, and that the iOS pool raises no software keyboard at all, so this
pass is more than a scene. The expander's and the toast's plans
(docs/expander-plan.md, docs/toast-plan.md) are the shape of this one;
docs/fullscreen-plan.md (immersive mode), docs/chat-plan.md and
docs/composer-plan.md (the composer above the keyboard) are what it meets.

Two words, used as the platforms use them:

- The SAFE AREA is the part of the window no system UI covers: not under
  the status bar, the Dynamic Island or notch, the home indicator, Android's
  navigation or gesture bar, or a display cutout. Apple's and Android's
  docs both use the term; Android's Compose name for the union that
  includes the keyboard is `WindowInsets.safeDrawing`.
- An INSET is the distance from one window edge to the safe area's edge on
  that side. The KEYBOARD here is the on-screen (software) keyboard, which
  Android calls the IME (input method editor) and which is an inset on both
  phones while it is up.

kaya's own `inset` window prop (DESIGN.md, Layout, "A normalized root
inset") is a different thing: kaya's padding, added inside the root. A
platform's safe area "was never part of it" (DESIGN.md), and this pass keeps
it that way.

## §0 — What the platforms offer, and what kaya does today

Rows marked MEASURED were measured for this pass (§7) on the lane pools
without editing anything; the captures are in the session scratchpad,
`safe-area-captures/`, each one viewed. The rest comes from the vendors'
documentation, cited at the end of the section; "to measure" belongs to the
depth or the breadth.

| | safe area by default | what extends under the bars | the keyboard | a focused field in a scroll | a bar that rides the keyboard | landscape and cutouts |
|---|---|---|---|---|---|---|
| iOS, SwiftUI | every view is laid out inside the safe area; `.ignoresSafeArea(_:edges:)` opts a view out | a `background(_:ignoresSafeAreaEdges:)` with a ShapeStyle extends into the safe area by default (iOS 15); a navigation or tab bar's own material runs to the edge | the keyboard is a SAFE-AREA REGION (`.keyboard`, iOS 14): content shrinks above it with no code; `.ignoresSafeArea(.keyboard)` opts out | a ScrollView's content inset follows the keyboard; whether it scrolls the focused field into view is to measure (UIKit's own text fields do in a UIScrollView only through app code; SwiftUI's Form/List do) | `.safeAreaInset(edge: .bottom)` places a view above the bottom safe area, which includes the keyboard, so it rides | the safe area moves to the sensor housing's side in landscape and the home indicator stays bottom; the platform keeps content out of both |
| Android, Compose | NONE at targetSdk 35: Android 15 forces edge to edge, so a window spans the display and the bars draw over it; an app consumes `WindowInsets.systemBars`, `.displayCutout`, `.ime` or their union `.safeDrawing` itself | whatever the app draws before it pads; Material 3's TopAppBar and NavigationBar each pad their own content by the insets and run their container to the edge | `windowSoftInputMode`: `adjustResize` shrinks the window's insets area, `adjustPan` pans the whole window so the focused view shows; with edge to edge the IME is an inset (`imePadding()`, `WindowInsets.ime`) and `adjustResize` is the documented pairing | a focused text field requests bring-into-view on its scrollable ancestor (foundation's BringIntoViewRequester); whether it does so again when the IME grows after focus is to measure on foundation 1.11.4 | anything laid out after the IME padding sits on the keyboard's top edge | at target 35 a non-floating window lays out into the cutout on every side (`LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS`); `displayCutout` is part of `safeDrawing` |
| iPadOS, Android tablets | as the phones | as the phones | iPad's floating and split keyboards leave the keyboard safe area empty; a hardware keyboard shows only the shortcuts bar (to measure on kaya-sim-pad) | as the phones | as the phones | a stage-manager window or a split-screen app gets its own insets, possibly none |
| macOS | a fullscreen window on a notched display is kept below the notch by AppKit unless the app opts into the notch area; `NSScreen.safeAreaInsets` (macOS 12) names it | the window's own background | none (a hardware keyboard) | n/a | n/a | the notch, in fullscreen only |
| WinUI 3 | the client area; no safe area | the Mica or window background | the touch keyboard, on a tablet or with the keyboard forced: `CoreInputView.OcclusionsChanged` reports what it covers; the framework's ScrollViewer brings the focused element into view (documented, to measure on the VM) | the same | n/a | n/a |
| GTK 4 | the window; no safe area | the window | GNOME Shell's on-screen keyboard; GTK has no avoidance API of its own | n/a | n/a | n/a |

What kaya does today, MEASURED:

1. **iOS keeps every widget inside the safe area, with no code of kaya's.**
   On kaya-sim-0 (an iPhone with a notch, 375x812 points) the window
   metrics reporter reads `375x734`, the screen less 44 points of status bar
   and 34 of home indicator; the autofill form starts under its large title
   below the status bar and the tasks details screen's grouped ground runs
   edge to edge (KayaGroupedScreenGround's `.ignoresSafeArea()` on the
   background) while its rows stay inside. The section bar floats above the
   home indicator. The interpreter names `ignoresSafeArea` exactly once, for
   that ground; `safeAreaInset` only for the native table's apron.
2. **The iOS pool raises no software keyboard.** A programmatic focus
   (`click textarea@compose`, `click entry@note`, `click textarea@notes`,
   each followed by `expect_focused` green) shows the caret and no keyboard,
   on every capture: the headless simulators behave as if a hardware
   keyboard is attached. Nothing on the iOS lane has ever seen kaya with the
   keyboard up, except whatever XCUITest's own typing raises
   (tools/ios/xcuidrive/KayaDrive.swift reads `keyboards.count` and has
   logged both 0 and 1, docs/traps.md, "An iOS typing wait can succeed").
3. **Android pads the whole surface by `safeDrawing` and resizes for the
   keyboard.** KayaRoot's Box takes `safeDrawingPadding()` (since
   2026-09-03, docs/traps.md, "The top 24px of an Android kaya window") and
   the library sets `SOFT_INPUT_ADJUST_RESIZE` at mount (since 2026-09-25,
   the chat thread's pan). On the 360x800 dp pool phone with Gboard: the
   chat composer sits on the keyboard's top edge with the thread shrunk
   above it (IME frame `[0,525][360,800]`), and the quick-add sheet's field
   and Add button ride the keyboard inside Material's bottom sheet. Both are
   right.
4. **Android hides a focused field that is outside a scroll.** The autofill
   guest's root is a plain column; focusing its last field (`secure_field@pin[a]`)
   brings up the number pad (IME `[0,569]`) and the field stays below it,
   unseen. Nothing moves, because the column cannot scroll and resize
   leaves no pan. The same shape is every short form a guest mounts without
   a scroll.
5. **Android in landscape hides the focused field even inside a scroll.**
   Rotated (360 dp tall), the keyboard takes `[48,136][800,360]`, leaving
   112 dp under the status bar. The chat thread's focused composer is not on
   screen: the top bar and a squashed search field fill the strip. The tasks
   details screen's focused notes field is not on screen either: the top
   bar keeps its 64 dp and the section bar squashes over a scroll of no
   height. The autofill form's Note field is hidden too. Compose fields ask
   for no fullscreen (extract) editor, so the keyboard does not take over
   the screen the way it does for a View EditText.
6. **Android's section bar rides the keyboard.** On the details screen in
   portrait the five-tab bar sits on top of the keyboard, taking 64 dp of
   the space above it. Material's own apps and iOS's tab bar leave the bar
   under the keyboard.
7. **Android's bars do not extend.** With the whole surface padded, the
   window ground fills the strip under the status bar (it matches the top
   bar, so nothing shows), but under the section bar a 16 dp strip of
   window ground separates it from the gesture bar, where Material's
   NavigationBar runs its container to the screen's edge.
8. **Cutouts are honoured on Android.** With the emulator's tall-cutout
   overlay on, portrait content starts below the taller status bar and
   landscape content starts 48 dp from the cutout's edge, plus kaya's 16.
9. **The desktops have none of this to measure** on the lanes: no lane
   desktop has a notch in fullscreen, a touch keyboard or an on-screen
   keyboard.

Six facts decide the design:

1. **Both phones already keep content in the safe area by default**, iOS
   through SwiftUI and Android through kaya's own root padding. The default
   exists; what is missing is a way OUT for a picture or a canvas, and the
   bars' own grounds on Android.
2. **The keyboard is an inset on both phones**, so "above the keyboard" is
   the same rule as "inside the safe area", and a bottom bar laid out after
   the content rides the keyboard on both with no new mechanism.
3. **Resizing alone loses the field when the space is too small or the
   field cannot scroll.** iOS's keyboard region and Android's resize both
   shrink the space; neither moves a field that has nowhere to go. That is
   the defect class this pass exists for, and it is measured on Android.
4. **Bottom navigation does not ride the keyboard on either platform's own
   apps.** kaya's Android section bar does.
5. **The lanes cannot see the keyboard on iOS today**, so any iOS keyboard
   leg would pass vacuously. The harness must refuse a keyboard verb when
   no keyboard is up, and the lane must raise one.
6. **No platform needs the app to read the insets** for the default; only
   a full-bleed canvas or picture needs to know where the bars are.

Sources: Apple, Positioning content relative to the safe area
(developer.apple.com/documentation/uikit/positioning-content-relative-to-the-safe-area),
SafeAreaRegions (developer.apple.com/documentation/swiftui/safearearegions),
ignoresSafeArea(_:edges:)
(developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:)),
safeAreaInset(edge:alignment:spacing:content:)
(developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)),
background(_:ignoresSafeAreaEdges:)
(developer.apple.com/documentation/swiftui/view/background(_:ignoressafeareaedges:)),
NSScreen.safeAreaInsets (developer.apple.com/documentation/appkit/nsscreen/safeareainsets);
Android Developers, Display content edge-to-edge in your app
(developer.android.com/develop/ui/views/layout/edge-to-edge), About window
insets in Compose (developer.android.com/develop/ui/compose/system/insets),
Behavior changes: Apps targeting Android 15
(developer.android.com/about/versions/15/behavior-changes-15), Support
display cutouts (developer.android.com/develop/ui/views/layout/display-cutout),
Handle input method visibility
(developer.android.com/develop/ui/views/touch-and-input/keyboard-input/visibility);
Microsoft Learn, Respond to the presence of the touch keyboard
(learn.microsoft.com/windows/apps/design/input/respond-to-the-presence-of-the-touch-keyboard).

## §1 — What kaya has

- **The root inset.** `inset` (window prop, 16 by default) is kaya's
  padding inside the mounted root; `inset 0` puts content at the safe-area
  edge on the phones, never past it (DESIGN.md, Layout;
  docs/styling-plan.md D3). `expect_inset` and `expect_root_fills` read it.
- **The Android root.** `safeDrawingPadding()` on KayaRoot and
  `SOFT_INPUT_ADJUST_RESIZE` at mount, both held by check-universal-props
  (docs/traps.md, the two entries named in §0).
- **The iOS window metrics.** KayaWindowMetricsReporter reports the window's
  content size to the core (`kaya_window_metrics`), already less the safe
  area; the core uses it for breakpoints (docs/adaptive-layout-plan.md D3).
  No reading of the insets themselves reaches the core, and none of the
  keyboard.
- **Immersive mode.** `fullscreen` on a phone hides the status bar and the
  home indicator or navigation bar (docs/fullscreen-plan.md §3);
  `expect_fullscreen` reads the platform's own bar visibility.
- **Scrolling verbs.** `expect_scrolled_to`, `expect_revealed` (a text
  range), `expect_window`, `expect_at_end` (follows_end), `scroll_to_row`;
  none involves the keyboard.
- **`expect_no_clipping`**, which reads whether each label has the room its
  text needs; it does not read whether a widget is covered.
- **The composer and the thread.** The chat app's thread is a grown scroll
  that follows its end (docs/follow-end-plan.md) with the compose row after
  it in the same column (docs/composer-plan.md), which is already the shape
  that rides the keyboard (§0, item 3).
- **Sheets.** A sheet is a root-hosting modal (docs/sheet-plan.md), drawn by
  the platform, which handles its own keyboard on Android (§0, item 3); on
  iOS, to measure.
- **The toast** sits at the bottom of the window above its bottom bars
  (docs/toast-plan.md T8); it says nothing of the keyboard.
- **The lanes.** The Android pool raises Gboard on a programmatic focus; the
  iOS pool raises nothing (§0, item 2). Neither phone lane rotates a device
  today, and neither has a cutout configured beyond the iPhone's own notch.

## §2 — The rulings (RECOMMENDED 2026-10-09)

### A1 — The default: inside the safe area and above the keyboard, with no app code

RECOMMEND that every window lay its widgets out inside the platform's safe
area, and, while the keyboard is up, above the keyboard, on every platform,
with nothing in the app or the wire asking for it. kaya's `inset` stays its
own padding, added inside that area, and `inset 0` still means "at the safe
area's edge", never "under the bars".

Why: both phones already do this for content (§0, items 1 and 3), the
platforms' own defaults are this (SwiftUI's, and Compose's once the app
pads), and an app author who never thinks about notches is the common case.
Making it a ruling turns today's two separate fixes into a rule a gate can
hold on every backend, and gives the desktops the same sentence where they
have the concept (A13).

### A2 — The bars' own grounds extend under the bars; widgets never do

RECOMMEND that the GROUNDS kaya or the platform draws for chrome run to the
screen's edge, as the platform's own apps draw them: the window ground, the
grouped screen's ground (as iOS already does), a top bar's container, the
section bar's container, a sheet's surface. The CONTENT of those bars
(titles, tabs, buttons) and every widget stays inside the safe area. On
Android that means the root stops padding the whole surface by
`safeDrawing`: the top bar and the section bar consume their own side's
insets the way Material's TopAppBar and NavigationBar do, and the content
between them is padded by what is left (§3).

Why: today's Android strip under the section bar (§0, item 7) is the visible
cost of padding the whole surface, and it is the one place a kaya app does
not look like an Android app on a gesture-navigation phone. The rule is
the same sentence iOS already obeys, so the two phones end in one
semantics. No app code: a ground has no reason to stop at a bar.

### A3 — An app asks for full bleed per widget, with a `bleed` prop on an image, a video view or a canvas

RECOMMEND a new Bool widget prop, `bleed`, false by default, legal on
`image`, the video view and `canvas` only. A widget with `bleed` set extends
past kaya's inset and the safe area to the window's edge, on each side
where it already touches the root's content edge (nothing lies between it
and the edge but kaya's inset). The keyboard is never bled under: a bled
widget still ends above the keyboard. Containers do not take it: a
container's tint or `filled` ground follows A2's rule by itself, and its
children are widgets that must stay reachable. Interactive kinds do not
take it, since a button under the home indicator cannot be pressed.

Three shapes were weighed:

- A window prop (`bleed` beside `inset`) would put every widget of the
  window under the bars, the opposite of what the photo viewer or the video
  player wants: their picture bleeds, their buttons do not.
- An `ignores_safe_area` prop on any widget, SwiftUI's own spelling, would
  let an app put a text field under the home indicator, and would need a
  sentence per kind about what it means; a gate could not say which uses
  are wrong.
- The three kinds whose CONTENT is a picture are the cases the platforms'
  guidance names (a full-bleed photo, a video, a map or game surface), and
  "touches the edge" is SwiftUI's own rule for `ignoresSafeArea` on a view
  that is not at the edge (it has no effect there), so the iOS lowering is
  the platform's modifier and Android's is a measured rule (§3).

Not now: a reading of the insets for the app (A14). A bled canvas's draw
will run under the bars with no way to know where they are; that is the
named limit, ledgered at the depth.

### A4 — When the keyboard rises, the focused field is moved into view, by its scroll or by panning the content

RECOMMEND that, when the keyboard rises or grows while a text-taking widget
(entry, search field, secure field, textarea, number field, a rich
textarea) holds focus, kaya make the field's caret line visible above the
keyboard, in this order:

1. If a scroll lies between the field and the root, the nearest such scroll
   moves the field into view (its whole frame if it fits, else the caret's
   line), with the platform's own scroll and no animation of kaya's.
2. If no scroll lies between them, or the scrolls cannot move far enough,
   the CONTENT region (below the top bar and above the bottom chrome A6
   leaves covered) is panned up by what is still covered, and panned back
   when the keyboard goes or focus moves to a field that needs less. The
   top bar does not move. This is Android's `adjustPan` scoped to the
   content, which is what both phones fall back to in UIKit and in the View
   system.

Why: §0 items 4 and 5 are the defect: resize alone loses the field whenever
there is no room to resize into, which is every short form without a
scroll and nearly every screen in phone landscape. A rule that only scrolls
would leave the autofill form hidden; a rule that only pans moves a
scrolled thread's top off the screen for no reason. Panning the content and
not the window keeps the measured lesson of the chat thread (docs/traps.md,
2026-09-25): the top bar and status bar never leave.

Refused: making every window root scroll by itself. It would change what
`grow` means in every scene (a grown child in a scroll has no height to
share), and the derived form, the grouped screen and the table all lean on
the root not scrolling.

### A5 — The composer pattern: whatever follows the window's grown scroll rides the keyboard; a scroll that follows its end keeps its end

RECOMMEND no new prop for a bottom bar that rides the keyboard. The rule:
in a window whose root is a column holding a grown scroll, the children
after that scroll are laid out on the keyboard's top edge while it is up,
and the scroll gives up the space. A scroll with `follows_end` set that was
at its end when the keyboard rose stays at its end (the newest message
stays visible above the composer). A scroll not at its end keeps its first
visible row where it was.

Why: that is already the measured Android behaviour (§0, item 3) and
SwiftUI's default through the keyboard safe-area region, so the rule writes
down what two backends do and holds them to it. Every chat client keeps the
newest message above the composer when the keyboard opens; kaya's
follows_end (docs/follow-end-plan.md) is the prop that already means "the
reader is at the end", so it carries this half too. An explicit
`rides_keyboard` prop was weighed and refused: it would be a second way to
say what the column's order already says.

### A6 — Bottom navigation and a sheet's actions: the section bar stays under the keyboard; a sheet rides

RECOMMEND that the section bar (Sections presented as a bar) and a phone's
bottom toolbar stay where they are and are covered by the keyboard, on
both phones; Android's lowering hides its NavigationBar while the IME is
visible. A sheet's content follows A1, A4 and A5 inside the sheet. A toast
shown while the keyboard is up sits above the keyboard (T8's "above its
bottom bars", read with the keyboard as the lowest bar).

Why: iOS's TabView and Material's own apps both leave bottom navigation
under the keyboard, since switching tabs mid-sentence is not a thing users
do, and the 64 dp it takes are the difference between a visible field and a
hidden one in landscape (§0, items 5 and 6). The sheet already behaves on
Android; writing it down holds iOS to it.

### A7 — Landscape and cutouts: the same rules on every side

RECOMMEND that A1-A6 apply on all four sides, in every orientation: content
stays out of a cutout on whichever side it is (Android's `safeDrawing`
already includes `displayCutout`; iOS's safe area includes the sensor
housing), A2's grounds run under it, and A3's bleed covers it on the
touching side. When the space above the keyboard in landscape is smaller
than the top bar plus the focused field's caret line, A4's pan still keeps
the caret line visible, and the top bar is the part that may be covered at
the last resort, since a caret nobody can see makes typing impossible while
a covered title costs nothing until the keyboard goes.

Why: landscape is where §0 measured the worst failures, and the Android
pool rotates and emulates cutouts with no image change, so the lane can
prove it (§5). Fullscreen extract editing (the platform's old answer for a
landscape phone) is refused by Compose's fields today, and kaya should not
re-enable it: it hides the screen the user is typing about.

### A8 — Immersive and fullscreen: the bars' insets go, the cutout and the keyboard stay

RECOMMEND that with `fullscreen` on (docs/fullscreen-plan.md), the status
and navigation bars' insets read as zero while the bars are hidden, content
may use that space, and the cutout's and the keyboard's insets still apply.
A bled widget reaches the true screen edge on every touching side. When the
user swipes the bars back transiently on Android, content does not move
(the bars draw over it, the platform's own transient behaviour).

Why: this is what each platform's immersive mode does with insets
(Android's `systemBars` go invisible, `displayCutout` stays; iOS's
`persistentSystemOverlays(.hidden)` shrinks the safe area to the sensor
housing), so kaya adds nothing and states it so the harness can read it.

### A9 — The harness reads the platform's insets and frames, never kaya's model, and refuses when there is no keyboard

RECOMMEND three observations and one wall, every one read off the platform:

- `expect_keyboard on|off`: the platform's own keyboard: iOS's keyboard
  frame from `UIResponder.keyboardWillChangeFrameNotification` against the
  window, or the window's `keyboardLayoutGuide` height (to measure which is
  current under a SwiftUI host); Android's
  `WindowInsetsCompat.isVisible(ime())` on the root. On the desktops it
  reads `off` always; the phone lanes alone run `on`.
- `expect_safe <target>`: the target's frame in the window lies inside the
  platform's safe area (iOS: the hosting view's `safeAreaInsets`; Android:
  the root's `safeDrawing` insets, which include the keyboard) and, while
  the keyboard is up, above the keyboard's frame. With `bleed` set the
  verdict for a bled widget is `bleeds`, read as its frame reaching the
  window edge on its touching sides.
- `expect_insets "<top>/<bottom>"`: whether each edge has a nonzero
  platform inset, as words (`bar`, `cutout`, `none`), never numbers, since
  the numbers differ per device. Used by the fullscreen and landscape legs.
- THE WALL: every `type`, `press`, `set_text`, `compose` and `paste` aimed
  at a text-taking widget on a phone checks, after its action, that the
  keyboard is up and the target's caret line is visible above it, and
  refuses naming the field, its frame, the keyboard's frame and the
  window's size when either fails. A scene that types into a hidden field
  is then red on its own, without a new verb, which is the path nobody can
  avoid (CLAUDE.md, invariant 3). The `no keyboard` half has its own
  sentence that names a hardware keyboard as the cause it measured, so the
  iOS lane cannot pass vacuously.

Why: the model-read class (docs/segmented-plan.md G10) applies twice here:
kaya's model knows nothing of the keyboard, and the window metrics are a
size, not a frame. Byte-identical expectations need words, not points, so
the verdicts are `on`, `off`, `safe`, `bleeds` and edge words, with the
numbers only in the failure text.

### A10 — The phone lanes run with the software keyboard up

RECOMMEND that the iOS lane raise the software keyboard for every leg that
types (the Android pool already does), through a simulator setting found
WITHOUT erasing or rebooting the pool (docs/traps.md and the never-erase
rule; to measure at the depth: the per-device hardware-keyboard preference
and whether XCUITest's own typing forces the keyboard). If no such route
exists, the iOS keyboard legs are refused by A9's wall with its sentence and
the gap goes on the ledger, rather than passing.

Why: §0 item 2. A keyboard rule that one of the two phone lanes cannot see
is half a rule, and the wall in A9 would otherwise fail every iOS typing
leg the day it lands.

### A11 — Tablets: only a docked keyboard is avoided

RECOMMEND that A4 and A5 respond to the keyboard's DOCKED part alone: an
iPad's floating or split keyboard and a hardware keyboard's shortcuts bar
change nothing (iOS reports no keyboard safe area for them), and an Android
tablet's floating Gboard does the same through its IME inset. A form sheet
on an iPad is moved by the platform; kaya adds nothing.

Why: that is the platforms' own reading of the insets, so the rule costs
nothing and keeps a floating keyboard from panning a whole screen. To
measure on kaya-sim-pad and the Android tablet leg.

### A12 — The keyboard is dismissed the platform's way; kaya adds no dismiss

RECOMMEND no kaya-drawn "done" bar and no dismiss-on-tap-outside: the
keyboard goes when focus leaves a text field (the harness's existing focus
verbs), by the keyboard's own key, or by a scroll where the platform does
it (SwiftUI's `scrollDismissesKeyboard`, iOS 16, left at its default;
Compose leaves it to the IME). A number field's keypad, which has no Return
key on iOS, keeps the Done toolbar it already has (KayaDrive's
`keyboard_done` reads it).

Why: each platform's own gesture is what users expect, and a kaya bar would
be one more thing between the field and the keyboard's top edge.

### A13 — The desktops: the same sentence where the platform has the concept

RECOMMEND that the desktops answer A1 through what they already have: a
macOS fullscreen window on a notched display keeps AppKit's default (below
the notch) and a bled widget under SwiftUI reaches it; WinUI, when the touch
keyboard reports an occlusion, follows A4 through ScrollViewer's own
bring-into-view and pans nothing else; GTK has no on-screen keyboard API and
does nothing. No desktop lane runs a keyboard leg; `expect_keyboard`
answers `off` there.

Why: invariant 1 asks for one semantics wherever a platform can express it,
and these are the places the desktops can. None is reachable on the lanes
(§0, item 9), so it is stated, not proved, and named in the ledger.

### A14 — No inset reading for the app, now

RECOMMEND no occurrence or signal giving the app the insets or the
keyboard's height in this slice. A bled canvas draws under the bars blind
(A3). The ledger holds a DEFERRED entry, keyed on the first app that needs
to place its own drawing against the bars (the video editor's monitor or a
map), with the shape it would take: the safe area as four numbers in the
canvas's draw context, read by the backend at draw time.

Why: every case this pass serves is handled with no app code, and a reading
the app can act on is a new protocol surface with nine bindings' worth of
spelling; it should arrive with the app that forces it.

### A15 — The first homes: the chat composer, the tasks quick-add sheet and details screen, the autofill form

RECOMMEND the proofs live in apps that already type on phones:

- the chat app's thread: the composer rides the keyboard and the newest
  message stays above it (A5), in portrait and landscape;
- the tasks app: the quick-add sheet's field (A1 inside a sheet, A6), the
  details screen's notes field with the section bar left under the keyboard
  (A6), in landscape too (A4, A7);
- the autofill guest: a plain column with its last field below the keyboard
  (A4's pan, the measured Android defect);
- a new `safearea` scene for `bleed` (an image at the top edge, a canvas
  filling a window with `inset 0`) and the fullscreen reading (A8).

Why: three of the four are the measured failures and the fourth is the only
new surface; each is an existing guest whose captures the maintainer has
already reviewed, so a change is visible against them.

### A16 — `bleed` in all nine bindings and the C floor, live zone only

RECOMMEND every binding spell `bleed` as it spells the image's other Bool
props (a chained call, a keyword, a labelled argument), on the three kinds
in the LIVE zone. The template zone refuses it at the root with one
sentence: a stamped row never touches the window's edge, so bleed there
could only mean nothing. Every binding's template surface refuses it by type
where the zone has its own handle, as the canvas's size policy does.

Why: invariant 2's sweep with no carve-out, and the size-policy surface is
the precedent for a prop legal in one zone (CLAUDE.md, check-sugar-surface).

### Deferred, for the ledger at the depth

- The inset reading for the app (A14). KEY: inset reading, safe area occurrence, canvas insets.
- WinUI's touch keyboard and macOS's notch, stated and not proved on any
  lane (A13). KEY: touch keyboard, CoreInputView, notch, safeAreaInsets.
- Keyboard avoidance with a hardware keyboard's shortcuts bar on iPad
  (A11), to measure. KEY: shortcuts bar, floating keyboard.

## §3 — The lowering, per backend

| backend | the default (A1, A2) | bleed (A3) | the focused field (A4) | the riding bar and the covered bar (A5, A6) | the readings (A9) |
|---|---|---|---|---|---|
| SwiftUI, iOS | already: SwiftUI's safe area; grounds use the ShapeStyle background that ignores safe-area edges (the grouped ground's shape, applied to the window ground, the sheet and the bars) | `.ignoresSafeArea(.container, edges:)` on the bled view, the edges computed from the touching sides; never `.keyboard` | the nearest kaya scroll's ScrollViewReader scrolls to the focused field's id when the keyboard's frame changes (`keyboardWillChangeFrame`), unanimated; with no scroll, an `.offset` on the content root by the measured overlap (A4.2); to measure whether SwiftUI's own avoidance already covers case 1 | the column's children after the grown scroll need nothing (the keyboard region); follows_end re-asserts its end on the keyboard change; the TabView's bar `.ignoresSafeArea(.keyboard)` | the window's `safeAreaInsets` and keyboard frame through the hosting controller, the target's frame in window space through the existing frame readers |
| SwiftUI, macOS | already | `.ignoresSafeArea` (a fullscreen notch only) | none | none | `expect_keyboard` answers `off` |
| Compose | the root stops padding by `safeDrawing`; it pads by `displayCutout` and the IME, KayaMenuTopBar consumes `statusBars` (TopAppBar's `windowInsets`), the section bar's NavigationBar consumes `navigationBars`, the content between consumes what is left (`consumeWindowInsets`); `ADJUST_RESIZE` stays | the bled image, video or canvas skips the consumed padding on its touching sides (a measured offset with `layout`, since Compose has no `ignoresSafeArea`) | a `BringIntoViewRequester` on every text-taking widget, invoked on focus and again whenever `WindowInsets.ime`'s bottom grows while focused; with no scroll ancestor, an `offset` on the content Box by the overlap, read from `boundsInWindow` against the IME inset | children after the grown scroll sit above the IME padding as today; the NavigationBar is not composed while `WindowInsets.isImeVisible`; follows_end re-asserts its end | `ViewCompat.getRootWindowInsets` for `ime`, `systemBars`, `displayCutout`; the target's `boundsInWindow` (in the window's space, docs/traps.md's surface-space lesson applies to any pixel read) |
| GTK | the window; nothing to do | inert (no safe area), accepted | none | none | `expect_keyboard` answers `off` |
| WinUI | the client area; nothing to do | inert, accepted | ScrollViewer's own bring-into-view on the touch keyboard (documented) | none | `expect_keyboard` answers `off` |

## §4 — The wire

- One new widget prop, `bleed` (Bool, false), legal on `image`, the video
  view and `canvas`; its number is the build's. The root refuses it on any
  other kind and in the template zone (A16), each with its sentence.
- No new record, no occurrence (A14). The keyboard and the safe area are
  backend rules with no wire presence.
- The spec hash moves for the prop; the nine wire files, kaya.h and the two
  interpreters' hand-copied hashes move with it.
- Harness (not on the wire): `expect_keyboard`, `expect_safe`,
  `expect_insets`; A9's wall inside the typing verbs on the two phone
  harnesses; lane tables gain device rotation and, on Android, the cutout
  overlay, each restored and proved restored after its leg.

## §5 — The scenes and the sweep

Additions to existing scenes, run on the phone lanes (the card's
`xNxxN`), the desktops cutting the keyboard lines through their lane tables:

1. chat.steps: after `click textarea@compose`, `expect_keyboard on`,
   `expect_safe textarea@compose`, `expect_at_end scroll#0`; the A9 wall
   then holds every `type` that follows.
2. tasks.steps: the quick-add sheet's `expect_safe entry@quick` with the
   keyboard up; the details screen's notes with `expect_keyboard on` and
   the section bar read as covered (`expect_safe` on a tab refuses, read as
   an expected refusal or through `expect_insets`).
3. autofill.steps: focus `secure_field@pin[a]`, `expect_safe` it (A4's
   pan); the wall holds the rest.
4. A landscape leg per phone (`chat`, `tasks` details, `autofill`) through
   a lane flag that rotates the device before launch and restores it, the
   restore read back (`user_rotation` 0 on Android; on iOS the driver's
   orientation, to add to KayaDrive) and refused if it did not take.
5. An Android cutout leg: the emulator's tall-cutout overlay on, the same
   scenes in both orientations, overlay off and read back after.
6. A new `safearea.steps` with its guest: a top image with `bleed`
   (`expect_safe image#0` reads `bleeds`), a widget under it (`safe`), a
   canvas with `inset 0` and `bleed`, `expect_insets`, then `fullscreen`
   on and `expect_insets` again (A8).

Every negative is a watched red (CLAUDE.md, invariant 3): the Android
root's old whole-surface padding put back (A2 red on the section bar's
ground), the bring-into-view on IME growth cut (landscape tasks red), the
content pan cut (autofill red), the NavigationBar left composed under the
IME (A6 red), `.ignoresSafeArea(.keyboard)` added to the iOS root (chat
red), each with its substitution count printed.

Gates that grow: check-verbs (the three verbs in both interpreters, and a
new routes table in tools/lib (`safearea_routes.py`, the expander's shape) holding each backend's insets reads, the
bring-into-view on IME growth, the pan, the hidden NavigationBar and the
wall in every typing verb, each cut watched red); check-sugar-surface
(`bleed` on three kinds, live zone, template refused, nine bindings,
fake-name and rename-in-a-copy negatives); check-universal-props (the
Compose root's per-bar inset consumption replaces today's whole-surface
clause, and `ADJUST_RESIZE` stays held); check-stubs (`depth_stub("safearea")`
on Compose until the breadth); check-steps and scene-features (the new verbs
key the feature, the desktop cuts); check-exclusive (the rotation and cutout
legs change device state, so each runs alone on its device and its restore
is part of the leg).

## §6 — Build order

1. The measurements §7 lists as the depth's, before any arm: the iOS
   software keyboard on the pool without a reboot (A10); whether SwiftUI's
   ScrollView brings a focused field into view by itself; the keyboard
   frame's source under a SwiftUI host; Compose foundation 1.11.4's
   bring-into-view on IME growth.
2. The depth: spec (`bleed`, its refusals), core and its unit tests, the
   harness verbs and A9's wall, the SwiftUI arm on iOS with the three
   readings, A4 and A5, the iOS lane's keyboard and rotation; the Rust
   binding; the chat, tasks and autofill additions and `safearea.steps`
   green on the iOS lane and on the mac (keyboard lines cut). The Compose
   depth stub; the DEFERRED ledger entries with KEY lines.
3. The breadth: the Compose arm per §3 (A2's per-bar insets, A4, A6),
   the Android landscape and cutout legs; GTK and WinUI accept `bleed`
   inertly and answer `off`; the eight other bindings and the C floor.
4. The matrix once, then the review page: every phone capture of §0 again,
   in portrait and landscape, beside today's, plus the safearea scene and a
   fullscreen frame.

## §7 — Measured, and to be measured

- MEASURED 2026-10-09 (the Android pool, API 35, 360x800 dp, density 160,
  Gboard; installed rusthost and gohost APKs, launched by `am start` with
  a scene script and a `settle`, screencapped, `dumpsys window` and
  `dumpsys input_method` read): chat composer focused, IME
  `[0,525][360,800]`, the row on the keyboard's edge; tasks quick-add sheet
  focused, the sheet rides; tasks details notes focused, the section bar
  rides the keyboard; autofill `secure_field@pin[a]` focused, IME
  `[0,569]`, the field under it and nothing moved. Rotated with
  `user_rotation 1` and the `cutout.emulation.tall` overlay on one device:
  IME `[48,136][800,360]`, `displayCutout [0,0][48,360]`; the chat
  composer, the details notes and the autofill Note field each focused and
  not on screen; content 48 dp from the cutout plus kaya's 16; no
  fullscreen extract editor. The device was put back (`user_rotation 0`,
  overlay disabled, no cutout inset, the apps stopped) and read back.
- MEASURED 2026-10-09 (kaya-sim-0, iOS 26.5, the installed chatgo,
  autofillgo and tasksswiftui bundles launched by `simctl launch` with a
  scene script, `simctl io screenshot`): the window metrics read `375x734`
  on a 375x812 screen; content inside the safe area; the grouped ground
  edge to edge; the tab bar above the home indicator; three programmatic
  focuses each green under `expect_focused` and none raising a software
  keyboard. The bundles are installed on kaya-sim-0 only; the other
  devices refused the launch.
- Read from the tree 2026-10-09: KayaCompose.kt's KayaRoot
  `safeDrawingPadding()` and `setSoftInputMode(SOFT_INPUT_ADJUST_RESIZE)`;
  KayaSwiftUI.swift's one `ignoresSafeArea` (the grouped ground) and its
  `safeAreaInset` uses (the native table's apron alone); the immersive arms
  (`statusBarHidden`/`persistentSystemOverlays`, `WindowInsetsControllerCompat`).
- To measure at the depth: a software keyboard on the iOS pool with no
  reboot (A10); SwiftUI's ScrollView and a focused TextField with the
  keyboard rising; the keyboard frame under a SwiftUI host; iOS's sheet
  with the keyboard up; KayaDrive gaining an orientation verb.
- To measure at the breadth: Compose's bring-into-view when the IME grows
  after focus (foundation 1.11.4); a bled image under the status bar with
  `layout`; the NavigationBar hidden while the IME is visible; kaya-sim-pad's
  floating keyboard and the Android tablet leg (A11); WinUI's touch keyboard
  on the VM, if it can be forced without a touch device (A13).
