# App identity: one name, one mark — design brief (Phase I)

Status: **DRAFT for ratification. Nothing here is built, and nothing
should be built until the asks in the last section are answered.** This
document answers the ledger entry "kaya windows have no app icon"
(docs/deferred.md:2477).

Claims are marked [DOC] (platform documentation, cited by URL in the
research reports), [MEASURED] (run by this pass — the reports under
scratchpad/chrome/identity-{mac,winui,gtk,phones}.md and
app-identity-research.md, 2026-08-18), [REPO] (read from this tree),
[INFER] (reasoning from the above, and a depth slice must confirm it).

Every path and line this document cites was checked by the tree's own
gate before it was written down: `tools/check-doc-refs.sh --also
docs/app-identity-plan.md` passes (605 references, 47 line-anchored).

All four platform arms reported. Two of them **overturned assumptions
this brief started with** — GTK4's icon surface is not name-only
(I4a), and the identity name is not runtime-dead (I9) — and both
reversals are marked where they happened rather than smoothed over.
One question remains open and is named as a precondition in I8.

## 0. What this is for, in one paragraph

kaya has no app-identity vocabulary. An app cannot say what it is
called or what its mark looks like, no backend lowers either, and the
window a kaya app opens on Windows has an empty square where every other
Windows app since 1995 has its icon. The ledger's proposal was one
declared identity — a name plus icon bytes on the wire blob channel the
typeface already uses — lowered per platform. This pass measured what
that lowering can actually reach on each of the five platforms, and the
answer is more interesting than "wire it up". **The icon is genuinely
reachable at runtime as real pixels on macOS, Windows and Linux/X11, and
unreachable on iOS, on Wayland-under-GTK-4.18, and on Android's launcher
— and every reachable case carries a condition: an activation policy on
mac, a bindgen-filter change on Windows, a GTK version on Wayland. The
identity NAME is reachable and readable on Linux, nearly free on
Windows, and packaging everywhere else. Those two uneven halves are the
design question, and the ledger entry did not anticipate the unevenness.**

What the tree ships today, for the record **[MEASURED/REPO by the
arms]**: Android declares three hard-coded `android:label` literals and
**no `android:icon` anywhere — there is no launcher icon resource in the
tree at all**, the whole `res/` inventory being four files. iOS
assembles a real bundle with a real Info.plist but **no asset catalog,
no `actool`, no `CFBundleIcons`, not even `CFBundleDisplayName`**, so
the home-screen name is the scene binary's name. macOS runs bare
executables whose `Bundle.main` is a directory with a **zero-key** info
dictionary. Linux has **no .desktop file anywhere**. So kaya declares a
name on the two phones by accident of packaging, and a mark nowhere.

## I0 — the ledger names one thing and it is two

The entry lists WinUI's `IconSource`, mac's Dock identity, Linux's
.desktop icon and the phones' launcher icons in one breath. Those are
two surfaces with two different reachabilities, and the brief separates
them because they fail differently.

**Surface A, the in-window mark.** An icon drawn inside the app's own
window by the app's own toolkit, from the app's own bytes. Pure runtime.
Windows is the platform whose convention has one (caption left) and
whose toolkit hands us a slot **[MEASURED: the pinned winmd, I1]**. The
other four have no such convention to serve: a macOS document window
shows a proxy icon for its *file*, not the app's mark; modern Adwaita
header bars carry no app icon; the phones have no window chrome at all
**[INFER from each platform's shipping apps — a depth slice should
state this per backend rather than lean on this sentence]**.

**Surface B, the shell identity.** Dock tile, taskbar button, alt-tab
card, launcher, Recents. This is what "the app has no icon" usually
means to a user, and on every platform it is substantially a packaging
artifact: the .app bundle's `CFBundleIconFile`, the .desktop file's
`Icon=`, the AndroidManifest's `android:icon`, the asset catalog's
`AppIcon`. A runtime blob reaches a strict subset of it.

A design that promises one undifferentiated "app icon" and silently
delivers A on one platform and nothing on three is the silent-fallback
failure the typeface slice exists to prevent, one tier up.

## I1 — the per-platform lowering table

| platform | what a RUNTIME blob reaches | what it cannot reach | evidence |
|---|---|---|---|
| **macOS** | `NSApp.applicationIconImage = NSImage(data: pngBytes)` replaces the **Dock tile and the Cmd-Tab switcher tile**, verbatim, from a plain PNG. No `.icns`, no multi-representation set, no `setName:`. | Anything before launch (Finder, Spotlight, Launchpad), measured from a separate process with nothing running. The switcher *label* and the Dock tile's AX title, which no route moved. All bundle identity. And **the tile only exists under `.regular`**: see I2. | **[MEASURED]** macOS 26.5.2 (25F84), unbundled probe reproducing kaya's dlopen+`@_cdecl` entry shape. Under `.accessory` the Dock strip was pixel-identical to baseline while the setter succeeded and read back 512x512. Under `.regular` the tile appeared as the generic black `exec` icon, then became the probe's magenta PNG; a real Cmd-Tab driven with synthetic events showed the same art in the switcher. It is **re-settable live** (a second icon installed at +9 s took effect in both places). The tile is **unmasked**: hard-edged square beside thirteen rounded system icons, so the blob owns its own shape — the bundled control with the same art in an `.icns` *is* rounded. |
| **Windows** | **Both sinks, from bytes, with nothing on disk.** The caption via `TitleBar.IconSource` ← `ImageIconSource` ← `BitmapImage.SetSource(InMemoryRandomAccessStream)`; the taskbar and alt-tab via `AppWindow.SetTaskbarIcon(IconId)` / `SetIcon(IconId)`, fed by PNG bytes straight through `CreateIconFromResourceEx`. | The AUMID display name and the relaunch icon, which are `"path,-resourceId"` strings pointing into a file on disk. `BitmapIconSource` is **URI-only**; `SetIcon(String)` is an **.ico file path**. Caption slot exists only on promoted windows: see I3. | **[MEASURED]** ECMA-335 table walk of the pinned winmd (Windows App SDK 2.2.0): `TitleBar.IconSource` typed `Microsoft.UI.Xaml.Controls.IconSource` on `ITitleBar` v1; `AppWindow` carries `SetIcon`, `SetTaskbarIcon` and `SetTitleBarIcon` in **both** String and `IconId` overloads. Of the seven `IconSource` subclasses only `ImageIconSource` reaches a stream-accepting type. **[DOC]** `CreateIconFromResourceEx` takes a memory pointer, and a PNG may be passed to it unmodified (Raymond Chen, "The format of icon resources, revisited"). |
| **Linux/GTK** | **X11: real pixels, today.** `gdk_toplevel_set_icon_list()` is public API taking `GdkTexture`s, and a blob decoded in-process lands as `_NET_WM_ICON` with no theme, no name and no file. **Wayland: nothing on this lane** — see I5a for why that is version-shaped rather than permanent. | The `.desktop` file's `Icon=`, which is what a Wayland desktop actually shows, matched by `app_id`. Packaging, on disk, ahead of the first window map. | **[MEASURED: GTK 4.18.6 in the lane container]** a 226-byte PNG → `gdk_texture_new_from_bytes` → `gdk_toplevel_set_icon_list` → `xprop` reads `_NET_WM_ICON(CARDINAL) = Icon (64 x 64)`. `gtk_window_set_icon` is gone in GTK4; the four surviving calls are name-only and resolve through `GtkIconTheme` **into that same GDK function**. Wayland's backend answers `GDK_TOPLEVEL_PROP_ICON_LIST` with a literal `break;`, and headless sway 1.10.1 advertises no `xdg_toplevel_icon_manager_v1` (full 53-global list read). Pins: `gtk4 0.11.4`/`v4_10`, libadwaita `0.9.2`/`v1_4` **[REPO: crates/kaya/Cargo.toml:151,175]**; the lane runs both protocols per leg **[REPO: tools/linux/run-suites.sh]**; there is **no .desktop file anywhere in the tree**. |
| **iOS** | Nothing. | The app icon is asset-catalog packaging; `setAlternateIconName` selects among **pre-declared** icons in `CFBundleAlternateIcons`, never bytes, and the system decides whether the user is prompted. The app-switcher card is a snapshot of the app's own UI, not an icon; any icon around it comes from the bundle. | **[MEASURED]** the full iOS 26.5 SDK header census of the app-icon surface is three symbols, typed `BOOL` and `NSString *` — no `NSData`, no `UIImage`, no `CGImage`. **[REPO]** tools/ios/Info.plist.in declares `CFBundleName` and no icon keys at all. iOS 18's Light/Dark/Tinted variants triple the *packaging* surface and add nothing runtime-settable. |
| **Android** | `ActivityManager.TaskDescription`'s **Bitmap** reaches the Recents card's icon — **and the arm recommends refusing to wire it anyway**, see I4 and I6. | The launcher icon (manifest-only, a compiled drawable). The Recents **label** is invisible to sighted users. | **[MEASURED]** against the pinned SDK's `api-versions.xml` and stubs, plus the actual consumer's source: see I4, the sharpest finding in this pass. |

## I2 — the mac row has a precondition, and it is a behavior change

The icon works unbundled. What it needs is `.regular`.

kaya's guests run `.accessory` under `KAYA_SELFTEST`, which is every
lane leg, and that is deliberate: an accessory app's windows do not
steal the human's keyboard while a suite runs. It is also why
`NSApp.isActive` is always false, which is the trap that
`kayaOpenPanelWhyNot` shipped for months (docs/traps.md).

**[DOC]** `NSApplication.ActivationPolicy.accessory`: "The application
doesn't appear in the Dock and doesn't have a menu bar." So under the
policy the lanes run, there is no tile to put an icon in, and the
measurement confirms it: the setter succeeded, the readback showed the
image installed, and the Dock did not change by a single pixel.

**So a declared app identity implies an activation-policy decision, and
shipping apps and lane legs cannot both have it.** That is a maintainer
question, not a lowering detail, and it is one of this brief's
ratification asks. The honest options:

1. The mac lowering applies the icon unconditionally and the Dock shows
   it only for apps that are `.regular`. Lane legs stay `.accessory`
   and the mac row is **unobservable on the lane** — which means the
   scene cannot assert it on mac, and a lowering nobody watches is a
   lowering that rots.
2. The identity scene's mac leg runs `.regular` specifically, accepting
   that this one leg takes the front. The keyboard-stealing risk is
   real and the matrix runs five lanes concurrently.
3. mac is a stated divergence for this slice and the icon ships on
   Windows first, with mac following once the policy question has its
   own answer. Note this option interacts with I6's recommended phone
   refusal: take both and the first slice is Windows alone, which is a
   thin fan-out by this repo's standards and should be chosen with eyes
   open rather than by accumulation.

## I3 — the Windows caption slot is not reachable on every window

`crates/kaya/src/winui/mod.rs:581` states the rule for
`window_titlebars`: the custom `TitleBar` control is "Minted by the SAME
first promotion that mints the CommandBar and by nothing else: extended
is DERIVED from toolbar presence, so a window whose catalog promotes
nothing never has one and keeps the standard system caption it always
had." **[REPO]**

So lowering the identity into `TitleBar.IconSource` alone would put the
app's mark on some kaya windows and not others. That is not an app
identity; it is a toolbar decoration.

**The resolution is the tree's own idiom and it makes the row
stronger.** Windows has two sinks: the **window icon**
(`WM_SETICON` / `AppWindow.SetIcon`), which every window has whether or
not kaya minted a custom caption, which the *system* caption draws at
its left edge unprompted — literally the convention the ledger cites —
and which the taskbar and alt-tab also read; and `TitleBar.IconSource`,
needed precisely because a custom caption replaces the system one and
takes the system-drawn icon with it. One declaration, two sinks, the
second repairing what the first gets for free elsewhere. The caption
*text* already has exactly this shape in the tree: the control's title
is documented as "a SECOND SINK for the composed caption, never a second
author of it".

**The byte chain for the window icon, measured end to end in the
metadata and the docs:** PNG blob → `CreateIconFromResourceEx` (a memory
pointer; a Vista-or-later icon resource may itself be a PNG, so the blob
goes in unmodified) → `HICON` → `Windowing_GetIconIdFromIcon` →
`IconId` → `AppWindow.SetTaskbarIcon(IconId)`. Nothing on disk, nothing
packaged. One wrinkle the depth slice must carry: that interop function
is **not WinRT** — it is a flat export of
`Microsoft.Internal.FrameworkUdk.dll` resolved by `GetProcAddress`, and
the pinned header states it works in unpackaged apps only after
`MddBootstrapInitialize`, which kaya already calls. The shim is the same
shape as the `IWindowNative` one already in the tree.

**One trap found before any code was written, and it blocks both
sinks:** kaya's committed bindings **elide exactly the members this
needs**. `crates/kaya/src/winui/bindings.rs` carries `IconSource: usize`
and `SetIconSource: usize`, and every `…WithIconId` overload on
`IAppWindow`/`IAppWindow4` is a `usize` stub too — windows-bindgen's
"slot reserved, method not projected" placeholder, because
`IconSource`, `ImageIconSource` and `Microsoft.UI.IconId` are all absent
from tools/winui-bindgen's filter list. What that leaves reachable is
**only the overloads that demand an .ico path on disk**. Step one of any
implementation is a bindgen-filter change and a regenerate. **[MEASURED]**

**And this is the argument that makes the whole design worth having.**
kaya's Windows guests do not run one executable: the lane kills
`<scene>.exe`, `<scene>_go.exe`, `python.exe`, `dotnet.exe`,
`kaya-guests.exe` and `java.exe` **[REPO]**. Windows' documented fallback
for a window with no icon set ends at the *host process's* icon, so with
no runtime call the Python guest wears the Python icon, the Java guest
the JVM's, and the Rust guest whatever a resourceless exe gets. **A
build-time `.ico` cannot fix that, because kaya is a library loaded into
someone else's process in six of eight languages.** A runtime call from
libkaya reaches all of them identically, which is precisely what
invariant 1 asks for. There is no icon resource of any kind in the tree
today — no `.rc`, no `winres`, no `.ico` outside third_party
**[MEASURED]**.

**AUMID, and the overstatement to avoid.**
`SetCurrentProcessExplicitAppUserModelID` buys taskbar grouping,
jump-list identity and pinnability. **It draws no pixel** — the taskbar
button still shows the window icon. The icon and name that travel *with*
an AUMID are `System.AppUserModel.RelaunchIconResource` and
`RelaunchDisplayNameResource`, both `"path,-resourceId"` strings into a
file on disk, which is exactly where the runtime-blob model runs out on
Windows **[DOC]**. It is still worth calling for a reason that is not
about icons: kaya's Python, Java and dotnet guests currently group under
the **host** executable's taskbar button, which is the wrong bucket.
That is a real defect this slice is well placed to fix, and the brief
names it rather than smuggling it in as an icon benefit.

**Where the name goes on Windows, and where it must not.** Caption text,
taskbar tooltip and alt-tab label are one window-text string that kaya
already owns through `refresh_caption`. The identity name must feed
*that* function and **not** `TitleBar.Title`, which the tree
deliberately leaves empty: the control writes `appWindow.Title(...)`
itself and would become a rival author of the dirty marker
**[REPO/MEASURED]**. Rival authorship of the caption is a bug this tree
has already paid for once.

The good news beside it: **kaya already ships the bytes-to-BitmapImage
code one layer over.** The `Image` widget's blob arm in
crates/kaya/src/winui/mod.rs:10450 already does
`InMemoryRandomAccessStream` → `DataWriter` → `BitmapImage::SetSource`
on the UI thread. The caption lowering is that block with two lines
changed at the end. **[REPO]**

## I4 — Android: the modern API is ignored and the deprecated one works

This is the finding a doc page alone would have got wrong, and it is
recorded here because the brief would otherwise propose the wrong call.

- `TaskDescription`'s **Bitmap** constructors have been **deprecated
  since API 28**. **[MEASURED: the pinned SDK's api-versions.xml]**
- The modern replacement, `TaskDescription.Builder` (API 33), has at the
  tree's compileSdk 35 **only `setIcon(int iconRes)` — a drawable
  resource id, no Bitmap overload.** **[MEASURED: the pinned stubs]**
- AOSP **Launcher3/Quickstep's `TaskIconCache`** — what actually draws
  the Recents cards on stock Android — reads `desc.getInMemoryIcon()`,
  the **bitmap**, and the resource path is an unimplemented
  `// TODO: Load icon resource (b/143363444)`. **[MEASURED: the
  upstream source]**

So the non-deprecated API is ignored by the shipping consumer and the
deprecated one is honored. A real blob channel (`Builder.setIcon(Icon)`
with `Icon.createWithData(byte[])`) exists only from **API 37 (Android
17, June 2026)**, above the tree's pin and unavailable below it.

The label half is worse: the TaskDescription **label** reaches only the
Recents card's **content description**, the TalkBack string. The visible
title is the manifest label. A sighted user sees nothing change.
**[MEASURED: the same source]**

## I4a — Linux: the lowering is protocol-agnostic by construction

The GTK arm overturned this brief's working assumption, which was that
GTK4's icon surface is name-only and therefore hostile to a byte blob.

**`gdk_toplevel_set_icon_list()` is public API in the lane's own GTK
4.18.6**, takes a list of `GdkTexture`, and is what `GtkWindow`'s
name-based convenience calls into after resolving a name through the
theme. A 226-byte PNG decoded in process and handed straight to it
produced `_NET_WM_ICON(CARDINAL) = Icon (64 x 64)` on the X11 window,
with nothing on disk and nothing in the icon theme **[MEASURED]**.

**The same call is the Wayland path from GTK 4.20 onward.** GTK 4.20
(released 29-08-2025) implements `xdg-toplevel-icon-v1` by feeding *that
identical icon-list of textures* into `xdg_toplevel_icon_v1.add_buffer`
**[DOC: GTK NEWS 4.19.0 and the upstream source]**. So a lowering
written as "decode the blob to textures, hand them to the toplevel" is
correct on X11 today and correct on Wayland the day the lane's GTK and
compositor move. **Nothing in the design needs to be conditional except
the expectation of visibility**, which is the difference between a
carve-out and a version note.

Today, on this lane: GTK 4.18.6's Wayland backend answers the icon-list
property with a literal `break;`, and headless sway 1.10.1 advertises no
`xdg_toplevel_icon_manager_v1` **[MEASURED]**. So the honest sentence is
**"on Wayland the icon is the .desktop file's, and a runtime blob buys
nothing visible"** — true for GTK 4.18, with a known expiry.

**Two traps the depth slice must design against, both measured**, if the
name route is used at all: `gtk_icon_theme_add_search_path` scans at add
time, so bytes written afterwards stay invisible until the path is added
again; and `has_icon() == TRUE` is *not* sufficient, because an unthemed
flat PNG has empty `get_icon_sizes`, which makes GTK delete
`_NET_WM_ICON` silently. Going straight to `set_icon_list` avoids both.

**A defect found in passing.** tools/linux/run-suites.sh:164 claims
kaya's GTK windows carry `application_id("dev.kaya.Milestone2")` as the
reason its sway rule matches. The Wayland `app_id` actually follows
`g_get_prgname()`, not the GApplication id, so the lane's legs advertise
`python3`, `dotnet`, `java`, `milestone2`, `kaya-go` — one per launcher
binary. The lane is unaffected only because its rule is `app_id=".*"`.
The comment is wrong and should be corrected whether or not this slice
proceeds **[MEASURED: same binary under three argv[0]s gave three sway
app_ids]**.

## I5 — the wire shape

**One record, the `set_brand_typeface` shape verbatim.** A transaction
verb, not a window prop: WINDOW_PROPS (crates/kaya/src/spec.rs:219) is
per-window and identity is per-app. `title` already exists there and is
the *window's* title; the identity name is a different thing and the
vocabulary must not conflate them.

```
set_app_identity {                    // tx kind 44 (43 is the last today)
    mask: U32,        // bit 0 = an icon blob is present
    reserved: U32,
    name: Value,      // Str
    icon: Value,      // Blob; an empty Str rides the slot when absent
}
```

The mask-plus-always-written-slot convention, and the should_panic test
for "carries a blob but its mask says otherwise", are copied from
`set_brand_typeface` (spec.rs:1190) rather than reinvented.

**The walls, copied from crates/kaya/src/scene.rs:1663 with their
reasons intact:**

1. **Set once.** A second write dies in the root, in every language at
   once.
2. **Before the first mount.** So no backend shows an unidentified frame
   it must repaint.
3. **Empty is refused.** An app that wants the platform's own identity
   declares none at all — an empty string would sail through five
   lowerings and be indistinguishable from a default.
4. **The bytes are not inspected in the core.** The typeface's rule
   transfers exactly: whether a blob is an image is a question only the
   platform's own decoder can answer, and a guess that disagreed with
   the decoder would be worse than no answer.
5. **Not undoable.** `UndoVerdict::Refused`, beside the brand's
   (scene.rs:370). Identity is not state.

**Why the blob channel is the right home, on the tree's own doctrine.**
DESIGN.md:2360, "Icons want names, not bytes" — the argument that
produced the `symbol` enum — ends "**The Blob stays for genuinely
app-specific art.**" An app's own mark is the canonical case: no
semantic name exists for it, no platform symbol set contains it, and no
per-platform redraw is right, because the whole point is that it is the
same mark everywhere. And the channel is already carrying app art:
`SECTION_PROPS` and `MENU_PROPS` both have Blob `icon` slots
(spec.rs:317, spec.rs:347).

**The one caution the tree raises against itself.** Fonts were argued
onto the blob channel because "an asset pipeline offers fonts nothing
the blob channel lacks — **density variants and OS packaging are
raster-art concerns**; a font is one vector file"
(docs/styling-plan.md Slice 2b). The app icon is exactly the raster-art
case that sentence carved out. This brief answers it in I6 (one PNG in,
conversion in the lowering) and I7 (packaging is a separate slice)
rather than inheriting the font's answer.

**The eight-language fan-out is one line.** The `check_styling_point`
function in tools/check-sugar-surface.sh is already parameterised over
eight regexes, already has `brand_accent` and `brand_typeface` as rows,
and already carries its own watched negative (a fake point that must
fail in all eight). A new identity verb is one added call, not a new
gate. **[REPO]**

## I6 — refused, stated once

- **Per-window icons.** Identity is the app's. Windows is the only
  platform of five with a per-window icon concept (`WM_SETICON` targets
  an HWND **[DOC]**); mac, Wayland, iOS and Android have exactly one
  identity per app. A construct expressible on one platform of five is
  the shape this
  repo already refuses by name (chrome-plan.md's refusal of any
  `chrome`/toolbar-style prop, "a no-op on at least one platform in
  every variant surveyed").
- **Runtime icon switching.** The set-once wall is the brand's, for the
  brand's reason: a slot that could flip at runtime promises a
  theme-switching surface the vocabulary deliberately does not have.
  **Badges are a separate future** and are genuinely different — a
  Dock badge, a taskbar overlay icon, an Android notification dot are an
  app-STATE channel, not identity. Nothing in the tree claims that
  vocabulary today, and this slice does not take it.
- **Platform-specific icon formats.** One PNG in; each lowering converts
  (`NSImage(data:)`, `BitmapImage.SetSource`, a `Bitmap` decode, an
  HICON). No `.ico`, no `.icns`, no adaptive-icon layer pair on the
  wire. The observation in I8 is what makes this a tested claim rather
  than a promise.
- **Per-platform icon ART rows** (the typeface's `platforms` list
  transposed to blobs). Refused *for now*, and the reason is that the
  divergences that genuinely matter — mac's margin grid, Android's
  adaptive foreground/background pair, iOS's mask — are packaging-time
  transforms that a runtime slot cannot serve anyway. Re-open it when
  packaging lands, not before.
- **Vector identity.** `SvgImageSource` would accept it on Windows and
  the ledger's "Vector/resolution-independent app art" question
  (docs/styling-plan.md:236) stays open. Not this slice.
- **Synthesizing identity chrome a platform never shows.** The dirty
  carve-out's rejected alternative, in its own words: it "fails the
  carve-out test in reverse, expressing what no native app expresses."
  No fake app icon in an iOS navigation bar.
- **The phone icon lowering, both halves — recommended by the phones
  arm and put to the maintainer here.** Launcher identity on iOS and
  Android is packaging, and each platform's single runtime lever is the
  *same* lever: choose one of N icons you already shipped, by name
  (`setAlternateIconName` / `<activity-alias>`). Wiring Android's
  `TaskDescription` instead would be an **Android-only feature**, not an
  Android-only spelling, which is invariant 1's distinction: its bytes
  path is deprecated at API 28, its non-deprecated path is a compiled
  drawable (packaging again), each path is broken in the half the other
  works in, and the payoff is one small icon on one screen on stock
  Launcher3. A real blob channel exists from API 37 (June 2026) and can
  be revisited when the pins move.

## I7 — the packaging boundary, and the fork this brief cannot decide

The measurements put a fork in front of the maintainer that the ledger
entry did not anticipate.

Most of what a user calls "the app icon" is **build-time**, on every
platform: the mac bundle's icon, the .desktop `Icon=`, the Android
manifest's drawable, the iOS asset catalog. DESIGN.md:3566 already says
so for mac in the tree's own words — `cargo run` launches unbundled
binaries, and "a minimal `.app` bundle … is needed only for
bundle-identity features: the app-menu name, `Info.plist` behaviors,
TCC prompts, notifications." The name half of this slice is *already
answered against the runtime* there.

So "one declared identity lowered per platform" is right, but the
lowering is **partly a build step**, and kaya has no build-time identity
concept for guests at all — guests are just programs in eight languages.
The three shapes:

- **(A) Wire only.** Ship the record; each backend does what it can at
  runtime; packaging is a later, separate slice that will need its own
  declaration channel. Honest, small, and leaves the user-visible
  launcher icon unaddressed on every platform.
- **(B) Packaging only.** Skip the wire; grow a packaging step that
  consumes a name and an icon and emits bundle/.desktop/manifest/asset
  catalog. Addresses what users see, does nothing for the WinUI caption
  slot the ledger actually pointed at, and needs a declaration format
  kaya does not have.
- **(C) One declaration, two consumers.** The wire record for the
  runtime sinks (WinUI caption, mac Dock, Android Recents), and the same
  declared identity read by a future packaging step. The catch is
  mechanical and worth stating plainly: a packager needs the identity
  *before* the program runs, so it cannot come off the wire — it needs
  either a manifest file beside the guest or a probe run, and both are
  new machinery.

**This brief recommends (A) now with (C) as the stated destination**,
and asks the maintainer to confirm that reading rather than assume it.

## I8 — the observations, and what would be a lie

An icon read has three tiers and only the third is worth shipping.

1. **Echo of the kaya model.** Worthless, and the exact failure this
   repo hunts: chrome-plan.md's precondition 1 records
   `expect_menu_symbol` passing off the MODEL while the iOS bar rendered
   no symbol at all.
2. **Echo through the platform's own storage.** Set a property, read the
   same property back. Proves the call reached the toolkit and did not
   throw. Not proof that anything is drawn.
3. **A read of the artifact the shell or the render holds, in pixels.**

**Linux/X11 gives a real pixel read, with no new dependency.** `xprop
-id <xid> _NET_WM_ICON` decodes the property the app itself set — the
server's copy, not an echo of a GTK field — and `x11-utils` is already
in the lane image **[MEASURED]**. By contrast
`gtk_window_get_icon_name()` returns the string just set and proves
nothing. Getting the xid from outside the process needs a search, since
the lane runs no window manager **[INFER]**. There is **no icon read
under Wayland on this lane and none through AT-SPI at all** (the frame
exposes no Image interface), so an icon assertion on Linux is
**X11-only and must say so** rather than being skipped quietly.

**Windows has one real read, one echo, and one open question.**
`TitleBar.IconSource` read back is a pure **echo** and must not be
asserted. `ImageIconSource → BitmapImage.PixelWidth/PixelHeight` is
**real**: the number comes from the XAML decoder, and undecodable bytes
read `0x0` — and kaya's existing `image_size` already does exactly this
**[MEASURED]**. `WM_GETICON` is **real** and is what the shell reads;
kaya has the HWND through the existing `IWindowNative` shim.

**macOS has a real read with a named limit, and a trap sitting beside
it.** `NSApp.applicationIconImage` read back is **not** an echo: AppKit
stores a re-rendered 1024×1024 snapshot, so the object returned is not
the object handed in, and `sha256` of its TIFF is a stable per-input
fingerprint (identical across 15 runs for one PNG, different for
another) **[MEASURED]**. **What it cannot do is distinguish "stored"
from "shown"** — in the accessory arm this exact read reported a
512×512 image installed while the Dock had no tile at all. Any verb
reporting "icon applied" from this read alone **would have passed on
every lane leg**. A read that cannot tell those apart must say so, and
the diagnostic rule (invariant 3) requires it to print what it measured
rather than a verdict it cannot support.

The trap beside it is worth recording because it is this repo's exact
failure shape: setting `ProcessInfo.processName` made the in-process
menu-title API read the new name **while the rendered menu bar kept the
old one**, captured twice. An in-process assertion would have gone green
against a menu bar that never changed **[MEASURED]**. Apple's own docs
warn the property is not thread safe and that other machinery depends on
it. It is refused as a name route on those grounds.

**The one question this pass could not close, named as a precondition.**
No document states whether `AppWindow.SetIcon` routes through
`WM_SETICON`. If it does not, a `WM_GETICON` gate would be a **false
RED**. The winui arm wrote the probe but it did not run, so this is
[INFER] and it is the first thing the Windows depth slice must settle —
before any gate is written against `WM_GETICON`, not after.

**Android's read is real, and the arm traced it end to end.**
`ActivityManager.getAppTasks()` → `AppTask.getTaskInfo()` →
`RecentTaskInfo.taskDescription` returns the **system's merged**
description, not the object the app handed in. The icon takes a detour
through the filesystem on the way: `ActivityRecord.setTaskDescription`
writes the bitmap to a file and nulls the in-memory copy, so reading it
back is a Binder call into a system service that explicitly permits the
owning app. A harness comparing those pixels is not comparing the model
to itself, which reading the Compose model would be. **[MEASURED:
pinned SDK stubs plus AOSP `main`]** Two honest caveats: the pixel
getter `TaskDescription.getIcon()` is **deprecated at API 30** ("the
caller should keep track of any icons it sets … internally") even though
its body still works; `getLabel()` beside it is not deprecated and reads
clean.

**iOS has no honest read of pixels at all.** The full iOS 26.5 SDK
header census of the app-icon surface is three symbols —
`supportsAlternateIcons` (BOOL), `setAlternateIconName` (NSString),
`alternateIconName` (NSString). No `NSData`, no `UIImage`, no `CGImage`
anywhere. **[MEASURED]** `alternateIconName` returns a string the app
itself chose from a set the app itself declared; it can never report
what the Home Screen renders.

**The asset should be designed to make the read easy**, the way the
typeface scene vendored a family no platform preinstalls so a fallback
could never equal the expectation by construction. The icon's version:
vendor an asset whose pixels are trivially discriminable (four quadrants
in four unmistakable colors) and have the read report sampled quadrants
rather than a hash. A hash cannot survive the per-platform conversion
this brief is proposing; four colors can. Then a lowering that never
applied reports the platform default's samples, which cannot collide;
and the read *proves the conversion*, which turns I6's "one PNG in,
convert in the lowering" from a promise into something the scene tests.

**The watched negative writes itself**: send bytes that are not an image.
The lowering must leave the platform's default in place and say so, and
the read must report the default's samples. That is the typeface's
silent-fallback wall one tier up.

**Where a read is not available**, the `dirty` precedent governs
(docs/dirty-plan.md:93): the platforms with no chrome read the applied
state back through the interpreter — "state, not chrome, the honest
observable where no chrome exists; NOT vacuous: it fails if the prop
never applied". For an icon there is a better middle than dirty had: the
**decode result**. Reporting that the platform's own image decoder
produced an N×N bitmap is a real operation that fails on bad bytes,
where echoing the request is not.

## I9 — the name: weaker than the icon, but not dead (a reversal)

The icon has real runtime sinks that draw pixels. The name is weaker,
though **the Linux arm rescued it from the "reaches nothing" verdict
this section originally carried**, and the correction is worth stating
plainly because it changes the recommendation below.

**mac turns out to have a supported route too, and one that fits the
machinery kaya already owns.** Writing `NSApp.mainMenu.items.first.title`
renders the declared name in the menu bar, has **no ordering
constraint** (measured working 1.5 s after launch), and kaya already has
a `NSApp.mainMenu` mutation path in `kayaSyncMacMenuBar` **[MEASURED +
REPO]**. It reaches only the menu-bar title, not the About/Hide/Quit
item texts and not the window title.

**The mac name is PARTIAL and the vocabulary must say so.** No route
moved the Cmd-Tab label or the Dock tile's AX title, even when
`localizedName` itself had been changed. So a declared identity can
leave the menu bar reading "Aurora Notes" while Cmd-Tab still reads
`kaya-go` **[MEASURED]**. That is a divergence to state in DESIGN.md's
"Stated platform divergences" if the name ships, not something to
discover from a screenshot later.

**And there is a hard consequence for the wire design here.** The richer
route — injecting `CFBundleName` into the main bundle's synthesized info
dictionary, which does work and moves the menu bar *and* the window
title — must run **before the first touch of `NSApplication.shared`**.
In kaya that is before `KayaApp.main()` inside `kaya_swiftui_run`, which
is **before the wire is open**. So an identity arriving over the blob
channel in the build closure is already too late for that route
**[MEASURED: injecting in `didFinishLaunching` changed nothing]**. It is
also undocumented behaviour whose blast radius is the whole info
dictionary. The brief therefore proposes the menu-title route and
records the bundle-name route as the thing packaging would do properly.

Against the name: mac's app-menu name is bundle identity by the tree's
own DESIGN.md; the Windows caption title is the *window's* and is
already spelled by `window.title`, while the AUMID display name needs a
`.lnk` or a file resource; Android's is the manifest's, and the
TaskDescription label reaches only a TalkBack string; iOS's is
`CFBundleDisplayName`.

For the name: **on Linux it is genuinely runtime-settable and genuinely
readable.** `gdk_wayland_toplevel_set_application_id()` is public and
works (measured `app_id='dev.kaya.Brand'`), `g_set_prgname` is the other
spelling, and the `app_id`/`WM_CLASS` string is the one lever that
decides which `.desktop` the whole desktop matches the window to — which
is to say it is the lever that decides the shell's icon and label.
kaya sets **neither** today, so every lane leg advertises its launcher
binary's name and no `.desktop` could ever match it. And the read is
real and cross-process: AT-SPI's application accessible hard-wires
`Name` = prgname, `Description` = `g_set_application_name`,
`AccessibleId` = the application id, all three measured live through the
same stack the a11y legs already stand up **[MEASURED]**.

So the real decision is **whether the name field ships in this slice at
all**:

- **(a) Ship it with the icon.** Identity is one declaration and the
  field is what a future packaging step consumes. Risk: a field an app
  fills that shows nowhere on four platforms and that no observation can
  assert there — a slot that is green because it is vacuous, which this
  repo treats as worse than red.
- **(b) Ship the icon now, the name with packaging.** Risk: two slices
  touch one record. This is cheap — the spec ids are append-only
  already.

The tie-breaker the tree already uses: `dirty` shipped a prop that
lowers to nothing on two platforms and it was ratified, but only because
it "applies everywhere, reads back everywhere" (DESIGN.md:385) and the
phones' read is non-vacuous. The name clears that bar on Linux
outright, and on Windows through the caption text it already owns; it
fails it on the two phones and on mac. **On that evidence this brief
now leans to (a), ship the name with the icon** — the opposite of where
it leaned before the Linux measurements arrived, and the change is
recorded rather than quietly folded in, because the maintainer is being
asked to ratify the conclusion and not just the outcome.

## Dependencies and sequencing

**The depth platform is Windows, not mac, and that is a deliberate
departure** from the usual pattern (CLAUDE.md: land the protocol + one
backend on SwiftUI/mac first). Windows is where the ledger's slot is
waiting, where both sinks are reachable with no policy change, and where
the strongest honest read lives. Depth on mac would open with I2's
activation-policy question unresolved.

0. **Close I8's open question first.** Probe whether
   `AppWindow.SetIcon` routes through `WM_SETICON` on the real VM. It
   decides whether the Windows gate can read `WM_GETICON` at all, and
   writing the gate before knowing is how a false RED gets built.
1. Spec: `set_app_identity` + the apply record; the hash moves;
   everything regenerates in lockstep (invariant 7).
2. Core: the five walls with their unit tests, the undo verdict.
3. Windows depth: the bindgen-filter change and regenerate (I3's trap
   first, since nothing compiles without it — `IconSource`,
   `ImageIconSource` and `Microsoft.UI.IconId` all need adding), the
   window icon, the caption sink, the pixel read, the scene, the Rust
   guest.
4. The vendored asset and its licence hygiene, plus the three staging
   lines the typeface scene already established
   (guests/assets/, an env override, scp/adb/container paths).
5. Breadth: **Linux next, not Android** — it is the second platform with
   real pixels and a real read (`gdk_toplevel_set_icon_list` + `xprop`),
   and its arm is the one that already measured the whole path. Then mac
   behind whatever I2 is ratified as. Android only if I6's refusal is
   overruled. Then the seven remaining bindings' sugar.
6. Gates: one `check_styling_point` row, one `VERB_FEATURE` row in
   tools/lib/scene-features.py, check-verbs coverage in both
   interpreters, and the watched negative from I8.
7. DESIGN.md's "Stated platform divergences" gains whatever I2 and I9
   are ratified as, in the landing commit.

## What ratification is being asked for

1. **The wire shape** (I5): one `set_app_identity` record, the typeface's
   mask-plus-slot convention, the five walls copied with their reasons.
2. **The mac activation-policy question** (I2): which of the three
   options, given that lane legs are `.accessory` on purpose and an
   accessory app has no Dock tile to put an icon in. This is a
   carve-out-shaped decision and the standing rule says it is the
   maintainer's.
3. **The packaging fork** (I7): confirmation of (A)-now-with-(C)-as-
   destination, or a different reading.
4. **Whether the name ships in this slice** (I9), given that it lowers
   to nothing observable on four of five platforms.
5. **The refusals** (I6), particularly per-platform icon art, which is
   the one this pass recommends refusing *for now* rather than forever.
6. **The sequencing departure**: depth on Windows rather than mac, and
   Linux as the first breadth arm rather than a phone.
7. **Two findings that stand on their own**, whether or not this slice
   proceeds, and which the maintainer may want handled separately: the
   inaccurate comment at tools/linux/run-suites.sh:164 about where the
   Wayland `app_id` comes from (I4a), and the fact that kaya's Python,
   Java and dotnet guests currently group under the **host executable's**
   taskbar button on Windows for want of an AUMID (I3).

## Ratification record

- (nothing ratified yet — this document is the request)
