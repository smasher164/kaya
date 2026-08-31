# SAVE — winui arm (backend + deploy-win)

Charter: docs/save-plan.md D1-D5, docs/probes/save-depth.md §8 FROZEN
CONTRACT, docs/probes/save-probe-windows.md.

Files this arm owns: `crates/kaya/src/winui/mod.rs`, `tools/deploy-win.sh`.

Progressive log; verdict at the bottom.

## 0. Reading (in progress)

- save-plan D1: after a save dialog, opening the destination for WRITE
  yields an EMPTY file on every platform. The CORE absorbs the platform
  disagreement (`protocol::SaveDestination`, create on every mode,
  truncate on `Write`). **My arm hands the core the locator unchanged**
  and must NOT create the file itself.
- save-depth §8: no extensions, no filters on the save request, basenames
  only in dialog assertions, guest asserts BYTES, read back through the
  HANDLE.
- save-probe-windows §B: `IFileSaveDialog` (CLSID_FileSaveDialog), NOT
  `FileSavePicker`. Measured id map for the SAVE dialog:
  - title `"Save As"`, commit id=1 `"&Save"`, cancel id=2
  - **file-name box id=1001, class `Edit`** (no id 1148 at all; the OPEN
    dialog's 1148 is absent) — and `dialog_control` already matches on
    id AND class, which keeps (1001,"Edit") off the (1001,
    "ToolbarWindow32") address bar
  - list host id=1121 `SHELLDLL_DefView` — same as open, so
    `sample_folder_view`'s IShellBrowser→IFolderView walk should carry
    (probe ASSUMED, not measured; I measure it)
  - default options `0x880a` include **FOS_OVERWRITEPROMPT**: saving over
    an existing name puts up a SECOND `#32770` titled "Confirm Save As"
    whose buttons have **id=0** — found by class+text only. Until it is
    answered `Show()` NEVER RETURNS.
- The existing machinery I ride: one STA `dialog_apartment`,
  `DIALOG_QUEUE` + `DIALOG_DOORBELL`, `sampler` message-only window,
  `dialog_control` + POSTED messages (UIA is forbidden — the JVM-fatal
  `RPC_E_CANTCALLOUT_ININPUTSYNCCALL`), `capi::file_dialog_retire` +
  `Occurrence::FileDialogResult`.
- Starting state of my files: `winui/mod.rs` carries the depth arm's
  `ApplyOp::PresentSaveDialog(spec) => crate::depth_stub("save")` at
  6063; `deploy-win.sh` untouched.

## 1. THE BACKEND — written, compiles both feature configurations

`crates/kaya/src/winui/mod.rs`:

| piece | what |
|---|---|
| `sampler::Sampled` | an ENUM — `Open(dir, rows)` / `Save(dir, name)`. One process has one live dialog and this backend has one sampler window, so the two readers shared a slot; a pair of strings would have let `expect_file_dialog` accept a save dialog (empty rows) and `expect_save_dialog` accept a picker (first row as a name). The mac arm's two computed panel readers asking the TYPE, in this file's vocabulary. |
| `LiveDialog` | the thread-local's type: `IFileOpenDialog` and `IFileSaveDialog` are SIBLINGS under `IFileDialog`, so unlike AppKit there is no one type to hold. |
| `sample_folder` | the "where" half, asked of `IFileDialog` — both dialogs are one. |
| `sample_save_state` | `IFileDialog::GetFileName`, NOT the Edit's `WM_GETTEXT`: that lParam is a pointer, only `SendMessage` marshals one, and a send is the input-synchronous call that makes this dialog fatal to a JVM. It would be safe from the dialog's own thread, which is exactly the "safe in this one caller" reasoning that stops being true when the call moves. |
| `take_pwstr` | every Shell `PWSTR` is CoTaskMemAlloc'd and these reads sit inside a POLL. Also fixes the pre-existing per-row leak in the picker's sampler. |
| `file_save_show` | `CoCreateInstance(FileSaveDialog)` → `GetOptions\|FOS_FORCEFILESYSTEM` → `SetFileTypes`+`SetDefaultExtension` (only under a filter) → `SetFileName` → `SHCreateItemFromParsingName`+`SetFolder` → `Show(None)` → `GetResult` → `SIGDN_FILESYSPATH`. Creates NOTHING. |
| `DialogKind` | `Open { multiple }` / `Save { suggested_name }` — each field is meaningless to the other dialog, so a save request physically cannot say "name two destinations" (the type doing what `kaya_emit_save_dialog_result`'s single locator does on the answering side). |
| `run_dialog_request` | ONE answering path (D2: same occurrence, same live slot, same retire gate); the ONLY difference is the source — `PathSource` for a pick, **`SaveDestination` for a save**. That is D1 landing here: the backend hands the locator over unchanged and the core's create-and-truncate does the rest. |
| `ApplyOp::PresentSaveDialog` | the picker's arm with `multiple` → `suggested_name`; same apartment, queue, doorbell, and same `pending_dialog_dir` arming. |
| `ID_SAVE_FILENAME = 1001` | a DIFFERENT CONTROL, not the same id elsewhere: the save dialog has no 1148 at all, and the class half of `dialog_control` is what keeps (1001,"Edit") off the (1001,"ToolbarWindow32") address bar. |
| `save_dialog_state` / `set_save_name` / `confirm_save` | the three `Stage` methods, replacing the harness's panicking defaults on this backend. |
| `answer_overwrite_prompt` | see §2. |

### The overwrite prompt — kept ON, and answered

`FOS_OVERWRITEPROMPT` is in the save dialog's DEFAULT options (measured
`0x880a`). Clearing it would make Windows the only platform that replaces
a file without asking — NSSavePanel prompts too — so it stays, and
`confirm_save` answers it. Unanswered it does not fail, it WEDGES:
`Show()` never returns.

Found by IDENTITY, not caption and not shape. The caller already knows
which `#32770` it pressed Save on, so the prompt is "the other visible
one". Caption-matching would die on a non-English Windows; shape-matching
risks taking the save dialog itself mid-teardown. The press is the first
visible `Button` (its id is 0, so no id lookup finds it); measured order
is `"&Yes"` then `"&No"`, and guessing wrong CANCELS the save — a loud
failure — rather than a quiet overwrite. It logs once when it fires,
because the shared scene cannot reach it.

## 2. THE LANE

- `tools/guest/run_save_rust.cmd` — new, the checked-in launcher
  check-steps demands for every windows leg.
- `tools/deploy-win.sh`: `DEPTH_SCENES` default `save` (was empty),
  `save_rust` accepted as a single-suite argument, and
  `run_suite save_rust` between `drain_suites` in the depth block — the
  filedialog rule, not a new one: `live_dialog` walks the DESKTOP for a
  visible `#32770` and takes the first, so a picker up beside it means
  `file_dialog_name` types into whichever the walk reached first.

Gates: `check-targets windows` OK (BOTH feature configurations),
`check-shell` OK, `check-steps` OK, `check-stubs` OK.

## 3. THE LEG — green, and then a REAL DEFECT the leg could not see

First run: `save_rust: PASS (3s)`, every assertion, first try
(`save-win-1.log`). Notably `file_dialog_name final` → `expect_save_dialog
… final` passed in 21ms, which is the proof that `GetFileName` is a LIVE
read and not the echo of `SetFileName`.

Then I drove the platform's own edges with a SCRATCH scene on the VM
(`saveover.steps` + `run_saveover.cmd`, never in the repo, deleted after
— §6), because the shared script is byte-frozen and cannot reach them.

**THE DEFECT: the first burst of posted characters into a freshly created
save dialog's name box is DISCARDED.** Measured, and every step of the
diagnosis is in the record:

| experiment | result |
|---|---|
| type `decoy` into the process's FIRST save dialog | `save dialog names "copy", wanted "decoy"` after 15s of retries |
| same with `zzz` (matches no file) and `draft` | both fail identically — so it is NOT autocomplete or an existing name |
| same with a `settle 3000` before typing | fails identically — so it is NOT a readiness race that waiting fixes |
| type `zzz`, then COMMIT, then `dir` the scene directory | the file created is **`copy`** — so the keystrokes were LOST, `GetFileName` was not stale |
| instrumented: post, read back, post again | attempt 0 `dialog=0xd50584 edit=Some(1967526)` → reads `"copy"`; attempt 1, SAME dialog and SAME edit → reads `"zzz"` |

Why the leg was green anyway: `save.steps` shows a save dialog, CANCELS
it, and types into the SECOND one. So a guest that put up ONE save dialog
and typed a name would have saved under the SUGGESTED name with every
byte assertion still passing and pointing at the wrong file — exactly the
failure `expect_save_dialog`'s name half exists to catch, hiding one
dialog upstream of where the scene looks.

Fix: `set_save_name` posts AND VERIFIES in a loop, which is the shape the
other two dialog actions already had (`choose_file` and `confirm_save`
both post-and-check until the dialog goes). It was the one single-shot
action in the backend. Re-measured after the fix: the FIRST save dialog
takes the name in ~100ms, and the real leg still passes.

## 4. THE OVERWRITE PROMPT — driven, by hand

Scratch scene: save-as to `zzz`, save-back, save-as to `zzz` AGAIN. The
second commit raised the prompt and the backend answered it:

```
KAYA_HARNESS: +2525ms FileSave(true)
kaya: answered the save dialog's overwrite prompt "Confirm Save As" with "&Yes"
KAYA_HARNESS: +3109ms Expect(label#0, "saved third draft")
… KAYA_SELFTEST: OK
```

So the identity-based finder ("the other visible `#32770`") and the
first-visible-Button press are both measured working, and the wedge class
— `Show()` never returning — is closed.

## 5. FLIPS — both watched failing, both restored sha256-proven

| flip | substitutions | what failed |
|---|---|---|
| **A** — `SaveDestination` → `PathSource` in `run_dialog_request`'s save arm (delete D1's lowering) | 1 printed, restore 1 of 2 (the picker's arm legitimately reads `PathSource`) | `label#0 reads "saved save failed: The system cannot find the file specified. (os error 2)"`, cascading into the reopen and the AX read. **The save-BACK step still passed**, which is what shows the flip is scoped to the destination. |
| **C** — `ID_SAVE_FILENAME` (1001) → `ID_FILENAME` (1148, the OPEN dialog's) in `set_save_name` | 1 printed | `save dialog names "copy", wanted "final"` — and nothing else fails, because the bytes all land in the wrong file. That is the probe's measured trap (`dialog_control` finds no 1148 in a save dialog and the miss is SILENT), and the one assertion in the scene that can see it. |

Logs: `save-win-flipA.log`, `save-win-flipC.log`. Restores verified
against `winui-pristine.sha256` (`shasum -c` OK on all three files).

NOTE ON RESTORING IN A FAN-OUT: a sibling arm is editing
`tools/deploy-win.sh` at the same time (the `unit_tests_on_windows` phase,
D3's third defect, arrived mid-session). Every flip and restore here was a
TARGETED python substitution with the count printed and a zero refused —
never a checkout — so no sibling's work could be clobbered. The sha256
baseline was re-taken after their edit landed.

## 6. THE LANE — GREEN TWICE

| run | verdict | legs | save leg | suites |
|---|---|---|---|---|
| `save-win-lane-1.log` | **rc=0** | **149 PASS, 0 FAIL** | `save_rust: PASS (3s)` | 230s |
| `save-win-lane-2.log` | **rc=0** | **149 PASS, 0 FAIL** | `save_rust: PASS (3s)` | 140s |

Both runs also carry the sibling arm's new phase green:
`deploy-win: 4/4 unit tests passed on the guest (capi::picked_tests …)`.

One transient worth recording: a deploy failed the **build-id** guard
(`kaya.dll … STALE — carries dcd951408c112152, but core in this tree is
cc44950a309496fe`). That is the guard working, and the cause was the
fan-out rather than a defect: a sibling arm edited a file under `crates/`
during my 16s build, so the id baked by `build.rs` no longer matched the
tree by the time the verifier asked. The next deploy was clean. Anyone
running a lane during this fan-out should expect it and simply re-run.

## 7. CLEANUP — proven, not asserted

- **VM processes:** `tasklist` filtered for `save.exe|filedialog|
  milestone2|entry.exe|python.exe|java.exe|dotnet|kaya-guests|
  kaya-unittests|go.exe` → **empty** (grep rc=1).
- **VM windows:** none. A live dialog needs a live process and the list is
  empty; the last lane run ended rc=0 with every leg writing `EXIT=`.
- **VM scratch:** `C:\kaya\scenes\saveover.steps`, `C:\kaya\run_saveover.cmd`,
  `C:\kaya\out_saveover.txt` deleted; scheduled task `kaya_saveover`
  deleted and `schtasks /query` now answers "cannot find the file
  specified". The scratch scene and launcher never entered the repo.
- **VM disk:** the 15 `%TEMP%\kaya-save-<pid>` directories the legs and
  probes left are deleted; `dir %TEMP%\kaya-save-*` → **File Not Found**.
  `C:\kaya\kaya-unittests.exe` → File Not Found (the sibling phase removes
  its own). `kaya-picked-*` left alone — those are the filedialog legs',
  pre-existing convention.
- **Host processes:** `ps -Ao pid,etime,pcpu,command` filtered for
  `deploy-win|save.exe|cargo (build|test|check)|xwin` → **empty**.
- **Host disk:** this arm's scratchpad artifacts total **864 KB** (two
  lane logs at 260 KB each, five leg logs, the report, the sha256 file and
  the two scratch scene files). The scratchpad as a whole is 83 MB, shared
  with the other arms.
- **Source instrumentation:** the temporary `eprintln!`s used to diagnose
  §3 are gone — grep for `eprintln` on the same lines as `set_save_name`
  / `answer_overwrite_prompt` / `attempt` returns nothing.

## 8. FOR THE COORDINATOR

1. **`Stage`'s three save methods can lose their panicking defaults once
   GTK and Compose implement them** (harness.rs:838-874 says so in its own
   doc: "the moment all four backends implement them, drop the bodies and
   end the signatures with `;`", and `tools/lib/stage-coverage.py` then
   holds them like every other observation). WinUI is done; mac was done
   by the depth arm.
2. **`tools/check-steps.sh`'s serial-leg clause should grow `save`.** It
   pins `run_suite (menus|filedialog)_` legs to run alone between
   `drain_suites`; the save dialog is the same OS-global `#32770` found by
   the same desktop walk, so it needs the same rule. `deploy-win.sh`
   already runs it that way — the gate just cannot see that it must. One
   token: `(menus|filedialog|save)` at check-steps.py:2424, plus a
   self-test line beside the two already there. NOT DONE HERE because
   check-steps.sh is a shared gate file and this is a concurrent fan-out.
3. **The first-post-is-discarded finding is not Windows trivia.** Any arm
   whose harness types into a freshly created dialog with POSTED input
   should post-and-verify rather than post-and-hope; the shared scene
   cannot catch it because it types into the SECOND save dialog.
