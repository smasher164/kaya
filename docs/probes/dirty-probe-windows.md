# Dirty-state probe — WINDOWS arm

Probe-before-arm recon for the `dirty` window attribute. Nothing here
ships; `docs/` untouched; no repo file changed. Repo HEAD 1d2cf95.

Measured on the VM: `akhil@192.168.64.2`, Windows 11 Pro build 26200
(arm64), console session 1 Active, virtual screen 1824x768.
Probe ran 2026-08-05 23:25–23:29 local.

**Verdict in one line:** Windows has *no* document-modified affordance
of any kind — the marker can only be title text — but the observability
is already free and already honest: `expect_title` on WinUI reads the
real OS caption, proven by rewriting the caption from another process
and watching the in-guest harness follow it.

---

## 1. How kaya's WinUI backend sets a window title today

The call is `Microsoft.UI.Xaml.Window.SetTitle(&HSTRING)` — the
projected WinRT property, not `SetWindowTextW`. There are **five** call
sites in `crates/kaya/src/winui/mod.rs`, and that count is the first
cost a title-composed marker pays:

| line | site | what it writes |
|---|---|---|
| 5968 | `setup()`, window creation | `"kaya milestone 2"` (+ recording slot suffix) |
| 4497 | `ApplyOp::SetWindowProp` / `WindowProp::Title` | the app's title, **only if no nav entry covers it** |
| 1330 | `apply_split`, split presentation | top entry's title, else the window's own |
| 1364 | serial nav, entry covering | `entry.title` |
| 1372 | serial nav, empty stack | the window's own |

State: `core.window_titles: HashMap<u64, String>` (mod.rs:230), written
at 4491, cleared at 4560. The guard at 4497 is the shape to notice:

```rust
core.window_titles.insert(window.0, title.clone());
let covered = core.nav_stacks.get(&window.0).is_some_and(|s| !s.is_empty());
if !covered {
    target.SetTitle(&HSTRING::from(&**title))?;
}
```

So the displayed caption is **already a computed composition** of (the
window's own title, the nav stack top). A text marker becomes a third
input to that composition and every one of the five sites has to apply
it, or the marker blinks out on a nav push, a pop, or a split-mode
change. GTK's arm has the identical five-site shape (`gtk.rs:844, 938,
946, 993, 3342`) — the two platforms whose marker must be text are
exactly the two that inherit this problem. A platform with a separate
modified flag does not.

**Question the design must answer (not mine to settle):** when a nav
entry covers the window title, does the marker ride the entry title or
go away with the window's own? It is observable either way through
`expect_title`, and `tools/scenes/nav.steps` already asserts titles
across four pushes and pops (lines 9–24), so whatever is chosen shows
up in an existing scene immediately.

---

## 2. Is there ANY modern WinUI / Windows App SDK "modified" API?

**No. Measured against the metadata, not recalled.**

The undo recon's method was "confirmed by absence in kaya's own
generated bindings". That is weaker than it looks:
`crates/kaya/src/winui/bindings.rs` is *filter-generated* — 
`tools/winui-bindgen/src/main.rs` carries an explicit type allowlist —
so absence there only proves kaya never asked for the type. I searched
the metadata itself.

All 28 `.winmd` files under `third_party/winappsdk/**` (Base 2.0.4,
Foundation 2.1.0, InteractiveExperiences 2.0.15, WinUI 2.2.1) scanned
for any string containing `Modified`, `Dirty`, `Edited`, or `Unsaved`.
The complete hit list:

```
ModifiedRestingPosition       Microsoft.UI.winmd
ModifiedRestingScale          Microsoft.UI.winmd
get_ModifiedRestingPosition   Microsoft.UI.winmd
get_ModifiedRestingScale      Microsoft.UI.winmd
```

Those are `InteractionTracker` inertia modifiers — composition
scrolling, nothing to do with documents. There is no `IsModified`, no
`IsDirty`, no `DocumentModified`, no `HasUnsavedChanges` anywhere in
the Windows App SDK surface. Contrast AppKit's
`NSWindow.isDocumentEdited`, which the system itself draws as a dot in
the close button.

Adjacent surfaces checked and also empty:

- **UI Automation.** `WindowPattern` exposes `CanMaximize`,
  `CanMinimize`, `IsModal`, `IsTopmost`, `WindowInteractionState`,
  `WindowVisualState` — no modified property. Moot for kaya anyway:
  `crates/kaya/Cargo.toml` deliberately omits `Win32_UI_Accessibility`
  so that reaching for `IUIAutomation` fails `cargo build`.
- **Web check** turned up no Microsoft guidance documenting a
  modified-document convention for WinUI 3 at all — the title-bar docs
  cover setting the title, the icon, colors, and replacing the bar with
  app content, and stop there.

### The one Win32 API that names unsaved work — and it draws nothing

`ShutdownBlockReasonCreate` / `…Query` / `…Destroy` (user32) is the only
Win32 pair that means "this window holds work the user would lose". It
blocks system shutdown and shows a reason string on the shutdown
screen. Measured round-trip:

```
sbr.own   create=True  query=True   text=[kaya: unsaved changes] len=22
sbr.cross create=True  query=False  err=87 (ERROR_INVALID_PARAMETER)
```

So: it **round-trips in-process** (settable and readable, reason string
preserved), and the query does **not** cross a process boundary. That
in-process-only property is fine for kaya — `Stage::window_title` and
friends run inside the guest — but note what this API is and is not: it
draws **no window chrome whatsoever**. It changes only what the user
sees at shutdown. It is a plausible *extra* thing a `dirty` window could
do on Windows, not a lowering of the visible attribute.

---

## 3. What the marker looks like on screen

Probed against the **real deployed kaya WinUI window** (`C:\kaya\window.exe`,
the lane's own artifact, running the `window` scene), by rewriting the
same HWND caption from a second process and photographing each variant.
Window rect 52,52 → 708,491.

Every candidate round-tripped **exactly** (`match=True` on
`GetWindowTextW` == what was set, for all five), and every one rendered
in the caption with no tofu, including both non-ASCII candidates:

| variant | caption string | renders |
|---|---|---|
| baseline | `window probe` | — |
| leading asterisk | `*window probe` | yes, legible |
| trailing asterisk | `window probe *` | yes |
| leading bullet U+2022 | `• window probe` | yes, full font coverage |
| em dash U+2014 | `window probe — Edited` | yes, full font coverage |

Screenshots: `winarm/shots/win_*.png`.

Two things worth recording about the method:

- **The caption redraws on an external `SetWindowTextW`.** A WinUI 3
  window with the default (non-extended) title bar is an ordinary DWM
  caption over an HWND; the text is not re-asserted from any XAML-side
  copy. This is why the probe could measure five candidates without
  touching `crates/`.
- **The probe transcript mangled the non-ASCII, the window did not.**
  `out_probe.txt` shows `[ window probe]` and `[window probe - Edited]`
  because cmd redirected PowerShell output through the console
  codepage. The in-process comparison `$back -eq $v.t` was `True` in
  both cases and the screenshots show the glyphs, so the API path is
  exact and only the log lost bytes. (Worth remembering if a future
  arm asserts a non-ASCII marker through a Windows log file.)

**The taskbar shows nothing.** Windows 11's default taskbar is
icons-only with labels off, so no marker text reaches it
(`winarm/shots/taskbar_1lead_star.png`). The caption is the whole
visible surface on this platform.

---

## 4. The marker convention: what Windows apps actually do

Measured on Notepad 11.2606.15.0 (`Microsoft.WindowsNotepad_…_arm64`,
the packaged Store app — note `System32\notepad.exe` is an app-execution
alias, so the pid `Start-Process` returns is not the window's owner).

```
clean:  win32=[Notepad]                       dotnet=[Notepad]
dirty:  win32=[*kaya dirty probe - Notepad]   dotnet=[*kaya dirty probe - Notepad]
```

So the caption convention is **leading asterisk, no space, prefixed to
the document name**: `*<doc> - <App>`. Not trailing, not a bullet.

**But the visible chrome is not the asterisk.** Notepad extends content
into its title bar and draws a tab strip there, so the OS never paints
that caption string. What the user sees is a **dot in the tab's
close-button slot** — the VS Code / browser-tab idiom
(`winarm/shots/win_6notepad_dirty.png`). The asterisk still lives in the
HWND caption for the taskbar, Alt+Tab, and automation. Independent
reporting on the Windows 11 Notepad describes the same dot indicator.

The useful reading of that for kaya: on Windows the *state* is
conventionally carried in the caption string as a leading `*`, while the
*picture* is whatever the app draws for itself. kaya draws a plain
system caption, so for kaya the caption string is both.

Also present on the VM if a future arm wants more samples: `mspaint`,
`write` (WordPad is gone — `wordpad` absent on build 26200); no VS Code.

---

## 5. OBSERVABILITY — how a leg reads the chrome (the important result)

**The plumbing already exists and needs nothing new.**

The chain: scene verb `expect_title` (harness.rs:962 parse, :2077
evaluate) → `Stage::window_title(window)` (trait at harness.rs:658) →
the WinUI implementation at winui/mod.rs:7437:

```rust
fn window_title(&self, window: u64) -> String {
    Self::on_ui_read(move |core| Ok(winui_window(core, window)?.Title()?.to_string()))
    .unwrap_or_else(|e| format!("<unreadable: {e}>"))
}
```

`tools/scenes/window.steps` claims this "reads the REAL materialized
title … never the scene model's copy". On Windows that claim is a
getter on the same WinRT object the setter writes, which is exactly the
shape that could quietly be an app-side cache. **I measured it rather
than trusting it.**

Method: run the real `window.exe` against a probe scenes directory
(`KAYA_SCENES_DIR` — harness.rs:91 makes scene scripts runtime files,
so this needs no repo change), holding the window open with `settle`
while a second process rewrites the HWND caption with `SetWindowTextW`,
then assert the **rewritten** string:

```
expect_title "window probe"
settle 12000
expect_title "window probe *"
```

Result:

```
PROBE2 hwnd=7996642 before=[window probe]
PROBE2 after=[window probe *]
KAYA_HARNESS: +0ms      ExpectTitle(None, "window probe")
KAYA_HARNESS: +12026ms  ExpectTitle(None, "window probe *")
KAYA_SELFTEST: OK (title "window probe", title "window probe *")
```

**`Microsoft.UI.Xaml.Window.Title` follows the OS caption.** A change
made entirely outside the process, never routed through kaya's model,
is what the in-guest harness reads. (Cross-checked from the other
direction: an earlier pass asserted the *stale* string after the same
rewrite and was still polling — failing — 14s later, against a
`POLL_DEADLINE` of 15s.)

Consequences for the design:

1. A dirty assertion on Windows rides `expect_title` with **zero new
   backend plumbing**, and it is an honest read: a WinUI arm that
   updated `core.window_titles` but never called `SetTitle` would fail.
2. Two other routes exist for anything that has to read from outside
   the guest (`GetWindowTextW` and .NET `Process.MainWindowTitle`, both
   verified to return the same string) — but neither is needed, and
   `deploy-win.sh` has no window-title reader of its own. The only
   ssh-side title read in the tree is diagnostic:
   `tools/guest/desk-warm.ps1` P/Invokes `GetWindowTextW` to name
   whatever window is holding the foreground. The lane's real title
   reads all go through the harness.

### The catch the design has to face: asserting it uniformly

Invariant 6 says scene scripts are shared verbatim and expected strings
are byte-compared across platforms. If Windows and GTK lower `dirty`
into the title text while macOS sets `isDocumentEdited` (which changes
no string), then **no single `expect_title` line can be right on all of
them**. Two further consequences:

- The marker's spelling would leak into every scene that asserts a
  title. `expect_title` appears in `nav` (×5), `panels` (×2), `split`,
  and `window` today; any of those that ever set `dirty` would need
  platform-diverging expected strings, which the shared-scene invariant
  forbids.
- Even within Windows, the composition question from §1 means the
  expected string depends on the nav stack.

So the observable ought to be its **own verb** with a uniform
observation string (`expect_dirty` / `expect_clean`, reported as e.g.
`"window dirty"` on every backend), implemented per backend — on
Windows by reading the caption and testing for the marker, on macOS by
reading `isDocumentEdited`. That keeps `expect_title` asserting the
*document name* and keeps the marker's spelling a backend detail rather
than a fact baked into shared scene text. Recommending the shape, not
deciding it — but the Windows measurements say the cost of the wrong
choice is paid in every title-asserting scene.

---

## 6. Cleanup — proven, not asserted

VM processes started by this probe: `window.exe` (twice, the real lane
artifact), `notepad.exe`, `powershell`, `wscript`. All stopped:

```
== PROOF 1: no probe processes ==
NONE (no window.exe, no notepad, no wscript, no powershell)
```

Scheduled tasks created: `kaya_dirtyprobe`, `kaya_dirtyprobe2` — both
deleted; neither appears in `schtasks /query`. (`kaya_deskwarm` remains
and is left deliberately: it is the lane's own task, recreated with `/f`
by every `deploy-win.sh` run, and deleting it would be the deviation.)

VM disk: probe files lived in `C:\kaya\dirtyprobe\` only — never in
`C:\kaya` itself, so the lane's deployed artifacts and their build-id
stamp were read and never written. Directory removed; verified
`DIRTYPROBE-DIR-GONE`. Contents were 13 PNGs plus 3 scripts and 4 logs,
**9.4 MB** — measured from the byte-identical copies pulled back to the
host, because the directory was deleted before I ran `dir /s` on it
(the size query mis-quoted and I removed the directory rather than
re-create it; the copies are the same bytes).

Lane artifacts untouched: `window.exe` and `kaya.dll` still stamped
08/05/2026 10:24 PM, unchanged.

VM healthy at exit: `query session` shows console session 1 Active, ssh
responsive. Never force-cycled or power-managed.

Host scratchpad: `winarm/` — 9.4 MB pulled back, trimmed to **604 KB**
by deleting the six full-screen captures and keeping the seven caption
crops the report cites. **This arm created and modified no repo file** —
no probe code went into `crates/`, `guests/`, or `tools/`. (`git status`
does show `tools/guest/record-win/Program.cs` modified: that is a
concurrent sibling arm's recording-mode fix, not mine.)
Note `scratchpad/dirtyprobe/ (gone)` belongs to a **concurrent sibling arm**
(its `probe.c`, `x11-leg.sh`, `wayland-leg.sh`, `out/`) — I created that
directory name first by accident, moved my files out to `winarm/`, and
left theirs alone. Do not delete `scratchpad/dirtyprobe/ (gone)` on my account.
