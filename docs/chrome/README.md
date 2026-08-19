# docs/chrome — frozen measurement reports from the window-chrome milestone

The per-platform measurement reports (2026-08-14 → 08-18) that code
comments cite by section: the toolbar lowering probes on all five
platforms, the WinUI caption work (hover clip, ellipsis box, the
VS Code-style centred title, the icon corner), the pasteboard witness
research, the SDK-generation scout, the SF Symbols rendered-name census,
and the assets survey. They are records, not living docs — the dates and
numbers inside are the point, so edits here are limited to fixing a path
the tree no longer has.

Two files are extracted vendor evidence, cited from winui/mod.rs BY LINE
NUMBER: `TitleBar-v220.xaml` and `v220-CommandBar_themeresources.xaml`
(WindowsAppSDK 2.2.0's generic.xaml slices). Their bytes are frozen —
reformatting them breaks every `:NNN` anchor in the comments that cite
them. `symprobe.py` is the probe script `sections-symbol.md` describes;
the two `.png` files are the captures the toolbar comments compare
against.

They were written to a session scratchpad during the milestone and cited
from code as `scratchpad/chrome/<name>`; scratchpads die on reboot, so
the cited set was landed here (2026-08-19) and every citation repointed.
Anything else from that scratchpad is recoverable from the session
transcripts under `~/.claude/projects/-Users-akhilindurti-Projects-kaya/`
— search for the filename and replay the Write/Edit payloads.
