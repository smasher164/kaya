# keyprobe — in-process keystrokes for the WinUI harness (throwaway)

Wired into no lane and no gate. It answers one question on the lane's
Windows 11 ARM64 VM: can the WinUI harness's `type` / `press return` /
`unfocus` / `shortcut` verbs deliver keystrokes to THEIR OWN window by
posting messages to the island's input-site HWND, instead of `keybd_event`
on the system input queue, so pooled legs can type at once — while the
keystroke still traverses the XAML keyboard path the shared scenes assert
(docs/submit-plan.md S5 and §3's WinUI row, docs/undo-plan.md A8,
docs/number-field-plan.md §5, docs/search-plan.md S5).

The shape is tools/win/undoprobe's: a probe module compiled INTO kaya.dll
behind an environment variable, a throwaway guest built through the
ordinary binding, and a temporary patch that wires both in. Two copies of
the one guest run side by side in the interactive session:

- the WITNESS takes the foreground (the harness's own dance), focuses its
  entry and idles, counting every PreviewKeyDown/KeyUp and text change that
  reaches it — "the foreground window received nothing";
- the DRIVER, behind it, refuses to measure while it is the foreground, then
  posts keystrokes to its own HWNDs and reads what landed.

What the driver measures, in order (the log is the record):

1. Q1, the HWND and the message shape — `milk` typed by eight routes into
   the entry (a TextBox), the entry reset between them: WM_KEYDOWN/KEYUP
   alone, KEYDOWN+WM_CHAR+KEYUP, WM_CHAR alone, each to the
   `InputSiteWindowClass` grandchild; the full shape to `GetFocus()` (the
   `arrow_step` target, skipped when NULL on a background window), to the
   `DesktopChildSiteBridge` and to the top-level (both expected NOT to
   land), and SENT rather than posted; then `Milk` with Shift held in the
   UI thread's key-state table (`SetKeyboardState`).
2. (c) native undo: `TextBox.CanUndo`, `Undo()`, `Redo()` after posted typing.
3. (b) the Return door: `submit_on_enter` on the entry, with and without
   the WM_CHAR a real Return leaves behind (a stray CR in the entry after
   the handled preview is a finding).
4. The `submits` textarea: Shift+Return (Shift in the key table, which is
   what the door's `GetKeyState(VK_SHIFT)` reads) inserts the newline;
   plain Return submits.
5. The number field: Return commits; a posted Tab moves the focus to the
   next entry and the focus loss commits.
6. The search field: a posted Escape clears.
7. `primary+z` with Control in the key table reaches the thread-scoped
   WH_KEYBOARD hook and activates Edit>Undo.

The witness's final line is `WITNESS VERDICT strays: ...`; the driver's is
`DRIVER VERDICT foreground_was_self=... landed_routes=[...]`. The research
behind the design, with sources, is the session's scratchpad note
(keyprobe-research.md).

## Run

Inside `nix develop`, with the VM up (tools/deploy-win.py's host):

    git apply tools/win/keyprobe/hook.patch
    tools/win/keyprobe/run.py akhil@192.168.64.2
    git apply -R tools/win/keyprobe/hook.patch

`run.py` refuses to run unless the patch is applied, builds kaya.dll and
`keyprobe.exe` with `cargo xwin build --locked --features harness`, verifies
the dll's build id, ships both into `C:\kaya\keyprobe` (never `C:\kaya`),
runs the lane's desktop warm-up, schedules the driver and then the witness
through `run-hidden.vbs` under `schtasks /it`, polls both logs for
PROBEDONE, prints them, and kills what it started. `--no-build` reuses the
last build.

Nothing here is a gate: the lane's deployed artifacts never gain the hook,
and the patch must be reverted before any other build of the tree (the
`[[example]]` it adds would otherwise ship a probe guest).
