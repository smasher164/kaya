# The text editor — the design pass

Status: SHIPPED 2026-08-10 (`47bd2ab`) — `guests/go/editor/editor.go`
and `tools/scenes/editor.steps`, with legs on all five lanes. E1-E5
below shipped as written; the toolbar the editor asked for came later
(docs/chrome-plan.md, `e6eca3f`).

THE FORCING ARTIFACT ITSELF (Akhil, 2026-07-24; started 2026-08-10,
once its prerequisite list emptied). Written in **Go**, because an
editor in Rust would be kaya testing itself and every awkward corner of
a BINDING would stay invisible.

## §0 — what is already ratified

- **Opens with an EMPTY BUFFER.** No file argument, no picker on
  launch. Saving exists now, so an empty buffer is a complete story:
  type, save-as, keep working.
- **Sublime-shaped**: one buffer filling the window, the menu bar above
  it. **No tabs, no panes** (2026-08-10).
- **No syntax highlighting in v1** (2026-08-09). Recorded as a future
  slice; the textarea foundation already put a rich-capable control
  under every platform so it stays cheap.
- **Ordinary regular expressions only** — no backreferences, no
  lookaround. The engine is the APP's (Go's regexp, which is exactly
  that dialect), never the framework's: the framework ships text RANGES
  and the app ships find (ratified 2026-08-06 with a 40-citation
  survey behind it).
- Open, edit, save, save-as, standard shortcuts, keyboard navigation.

## §1 — the decisions (PROPOSED; all five shipped as written 2026-08-10)

### E1 — the surface

Menu bar: **File** (New, Open…, Save, Save As…), **Edit** (Undo, Redo,
Cut, Copy, Paste, Find…). Every one of those is a kaya MENU ROLE that
already exists and already routes — the editor authors almost no
behaviour for cut/copy/paste/undo/redo, which is the point: the
forcing artifact should mostly USE the framework, and where it has to
work around one, that is the finding.

The find bar is an ordinary row of kaya widgets (an entry, prev/next
buttons, a match count) shown and hidden by the app. It is NOT a
framework component — that boundary is the ratified one.

### E2 — the document, and what the app owns

One buffer, one optional destination handle, one dirty flag. The app
owns its text (the uncontrolled contract), folds text_changed into it,
declares `dirty` on the window when its text differs from what was
saved, and clears it on save. Close confirmation is
veto_close + the dialog machinery, composed by the app — the shape the
dirty milestone deliberately did NOT build in.

### E3 — find uses the range primitives, and proves them

Matching is Go's regexp over the app's own text; the matches become
`highlight_ranges`; the current match becomes `select_range` +
`reveal_range`. This is the first REAL consumer of the ranges
milestone, and any friction it hits is a finding worth recording
rather than working around quietly.

### E4 — it ships as a scene, so the matrix owns it

`tools/scenes/editor.steps` + `guests/go/editor/` — one guest, legs on
all five lanes. That buys the editor the same proof every scene gets:
byte-frozen output compared across platforms, and check-steps
demanding a leg wherever the guest can run. An app that only a human
has ever run is an app nobody can change safely.

### E5 — what "done" means for v1

A person can: launch it, type, save-as to a new file, quit and reopen
that file, edit it, undo, save, find with a regex, and be warned about
unsaved work on close. Each of those is a step in the scene, on five
platforms, plus artifacts a human can watch.

## §2 — sequencing

1. The app + the scene + the mac leg green.
2. Legs on the other four lanes; the matrix.
3. ARTIFACTS: stills and a short film per platform, published — the
   deliverable a remote maintainer can actually inspect.
   STILLS DONE 2026-08-17, in two published pages that carry the editor
   on every platform: "kaya: one hex is the whole brand"
   (https://claude.ai/code/artifact/ff51f6d1-4003-4a5f-b98c-92a47d157452)
   and "kaya: one bit, five bars"
   (https://claude.ai/code/artifact/6235dd79-ab1a-4084-a665-01cdba080e1c),
   both re-shot 2026-08-17 under the modern generation.
   FILMS: DONE 2026-08-17 (ratified wanted the same day) — all five
   platforms, each film a real leg run whose full verdict was required
   before the film counted; the Android one ran twice because its first
   take caught the stale-title defect (fixed same hour, the frame made
   impossible). The films ride the styling artifact.

## §3 — not in v1 (recorded, not forgotten)

Syntax highlighting; tabs and panes; find-and-replace-all across a
selection; recent files (needs the bookmark/persistence machinery the
save plan deliberately left out); large-file performance work.
