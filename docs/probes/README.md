# docs/probes — recovered measurement reports from earlier milestones

The research and probe reports that code comments and plan documents
cite: the save-dialog probes on five platforms, the undo
reconnaissance and prior-art sweeps, the dirty-marker probes, the
text-range probe fleet and its editor/framework surveys, the Go
mobile-packaging contract, and `units/` — the fifteen per-language
offset-unit probe sources behind docs/ranges-units.md. They are
records, not living docs — the dates and numbers inside are the point,
so edits here are limited to fixing a path the tree no longer has.

Every file here was once in some session's scratch directory, which
dies on reboot; by the time the no-scratchpad-citations gate clause
landed (2026-08-19, tools/check-doc-refs.py), all of these were already
dead and were replayed byte-for-byte out of the session transcripts
under `~/.claude/projects/-Users-akhilindurti-Projects-kaya/` — each
file's Write/Edit payloads re-applied in order. Replay lessons for the
next recovery live in docs/traps.md ("Transcript replay").

`open-panel-phone.md` is the one non-verbatim member: the original was
a uiautomator XML dump pulled off an emulator (never written by a
session, so no transcript holds it); the file that stands in its place
records the measurement the dump existed to make.

## Added 2026-09-02/03, straight from the session that produced them

Three research families landed while their scratch directories were still
alive, so these are the originals rather than replays:

- `video-playback-2026-09-02.md` and its five companions (`-apple-winui`,
  `-android-gtk`, `-decoders`, `-editor`, `-framepath`): the video-editor
  milestone's research — platform players versus owned rendering, the
  decoder routes and their licences, the frame path, what an editor's
  preview needs, thumbnails and waveforms; ten rulings at the end.
- `js-mobile-2026-09-02.md` with `-android-engines`,
  `-multi-engine-precedents`, `-ts-without-node` and `js-mobile-probes/`
  (eight C probes against JavaScriptCore, re-runnable with
  `cc -o p p.c -framework JavaScriptCore`): what porting the JS binding to
  JavaScriptCore and to an Android engine would take.
- `js-jit-aot-2026-09-02.md` with `-android`, `-survey` and
  `js-jit-probes/`: whether "no interpreted JS" is achievable on either
  phone — it is not on iOS, by Apple's entitlement — with the wire-packing
  benchmark that showed the encoder, not the engine, is the cost. The
  ruling that followed (2026-09-03): the JS binding stays a desktop
  binding; docs/js-plan.md §5.
- `dnd-2026-09-02-apple.md`, `-android-toolkits.md`, `-gtk-winui.md`: the
  drag-and-drop platform surveys behind docs/dnd-plan.md.
