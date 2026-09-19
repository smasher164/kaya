# Windows typing: selection ordering and offset units

Measured 2026-09-19 on the Windows ARM64 lane through
`tools/deploy-win.py akhil@192.168.64.2 notes_rust`.

The first full matrix failed only notes_rust, with 281/282 Windows legs
passing. Mac 477, Linux 775, iOS 139, Android 148 and all 61 gates passed.
The Windows leg spent 150 seconds in ten failed assertions. Windows was
1439 seconds net against its 1350-second ceiling; those assertion waits
account for the excess. No toast was observed during the failing leg.

## Evidence and controlled reproduction

The initial bundle, run `20260919T201202Z-083809`, recorded text `abcd`
with no bold, followed by peer text `abcdZ` instead of `abcZd`. It did not
record the core selection or the derived edit. Added harness-only records:

- `type.caret`: widget, native UTF-16 endpoints, core UTF-8 endpoints,
  and native text byte length.
- `rich.edit`: widget, before/after byte lengths, reported selection,
  derived replacement range, inserted text, and inserted runs.

An ordinary instrumented rerun passed in 491 ms. Suppressing one
SelectionChanged callback, with one insertion counted before and after,
reproduced the original ten failures. Run `20260919T204058Z-008952`:

| Time | Reading |
| --- | --- |
| 236 ms | Native caret `3:3`, core selection `0:3`, text length 3 |
| 243 ms | Core edit `0:3`, inserted `abcd`, runs empty |
| 265 ms | First expectation of `0:4 bold` begins; it times out 15 seconds later |

The recorder contained 20 records, none dropped. This directly establishes
the failure mechanism under a missing selection report; the original
matrix lacked the readings needed to distinguish event delay from absence.
The core's R10 selection-placement rule remains unchanged.

## Fix and guards

The Windows type driver uses a mutable UI hop, moves the native caret in
UTF-16 units, and reports the corresponding UTF-8 end to the core before
injecting keys. With the asynchronous callback still suppressed, the fixed
notes leg passed in 955 ms, including the original formatting and peer
ordering assertions. Run `20260919T210809Z-013184`.

Removing the new synchronous report, one counted substitution, failed the
new core-selection assertion at `0:3` versus `3:3` before key injection.
Run `20260919T211044Z-014260`, 4-second leg. That abort skipped the ordinary
trace dump, so the guard now explicitly flushes it before either assertion.

Changing UTF-16 counting back to scalar counting, one counted substitution,
initially passed with a lone emoji: WinUI corrected the interior-surrogate
caret. The witness was strengthened to `👋a`. With the same mutation,
run `20260919T211555Z-015997` failed in 5 seconds: native caret `2:2`
in UTF-16, byte position `4:4`, core `5:5`, text length 5. Its bundle held
25 trace records, none dropped, including the correct earlier `d` edit.
The shared notes script now demands that edit explicitly and appends `x`
to `👋a`, expecting `👋ax` and edit `5:5`.

All mutations are removed from the final source. The guards run inside
the real Windows type verb and in the shared notes scene, not in an
optional probe. No wire, public binding, or editor semantics changed.
The existing Windows notes toast watch is unrelated and remains open.
