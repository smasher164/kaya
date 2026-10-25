"""The Linux lane's tables (tools/linux/run-suites.sh reads them through
tools/linux/scene-mods.py). `MODS` has the phone lanes' drop grammar
(tools/lib/scene_cut.py): a TUPLE OF BLOCKS, each (step specs, keep,
reason), each spec a leading run of words naming exactly one step; their
`append`, steps after the scene's last, `;`-separated; and the phones' `cut`,
(verb, keep), everything from that step on dropped."""

MODS = {
    # NO LINUX DESKTOP DRAWS A REPLY FIELD (docs/notification-reply-plan.md
    # R1): the lane's portal lists no reply purpose, so the capability reads
    # false and no user can reply here. The scene keeps the reply one block
    # that changes nothing after it, and that block is what goes.
    "chat": {"drop": ((('notification_reply 7003',
                        'expect label@preview[alex] "Glad you liked them"',
                        'expect label@unread[alex]'),
                       "expect_notification expect_badge",
                       "no Linux desktop draws a notification's reply field (R1)"),)},
    # The macOS native table's own keyboard (docs/styling-pass-plan.md Y4,
    # AMENDED 2026-10-17): GTK's table has no selection of its own to move.
    "tracks": {"cut": ("press down", "expect_tint expect_rows")},
    # THE X11 WINDOW'S CONTENT IS 1090 FOR A 1100 REQUEST (docs/traps.md, the
    # x11 lane's toplevel X window is BIGGER than its content): libadwaita's
    # sidebar is a quarter of the content, 272 there and 275 on wayland.
    "music_header": {"x11": {
        "drop": ((("expect_width column@library 275",), "expect_no_clipping",
                  "an x11 window's content is 1090 wide for its 1100 request"),),
        "append": "expect_width column@library 272"}},
    # GNOME'S FULLSCREEN HEADER BAR (docs/fullscreen-plan.md §9): hidden over
    # the content, revealed at the top edge. No other lane has a bar to read,
    # so this lane appends the reading after the shared scene.
    "fullscreen": {"append": 'expect_titlebar shown;click button#0;'
                             'expect label#0 "asked for fullscreen";expect_fullscreen on;'
                             'expect_titlebar hidden;move_pointer top;'
                             'expect_titlebar overlay;move_pointer center;'
                             'expect_titlebar hidden;move_pointer top;'
                             'expect_titlebar overlay;click button#0;'
                             'expect label#0 "asked for a window";expect_fullscreen off;'
                             'expect_titlebar shown;'},
}

# The scenes whose legs run on the wayland slots alone, each with the reason
# tools/linux/scene-mods.py --protocols prints for the x11 legs not run.
WAYLAND_ONLY = {
    "fullscreen": "Xvfb runs no window manager, and gtk_window_fullscreen asks "
                  "one through _NET_WM_STATE: measured doing nothing there "
                  "(docs/fullscreen-plan.md §4.2)",
}

# THE QUIET TAIL (the maintainer's ruling of 2026-10-16, android's QUIET one lane
# over): these scenes' legs run in a `linux-quiet` row after every lane and the
# sweep (KAYA_QUIET=skip on the parallel lane, =only after), each with its
# reason. tools/check-exclusive.py holds the set, tools/check-gates.py the order.
QUIET = {
    "media_tracks": "the play-through's second cue is a 1 s window, and a matrix "
                    "stops the docker VM for longer (docs/traps.md, a linux VM off "
                    "every CPU for longer than a cue loses the cue)",
}


def quiet_legs(run_suites):
    """Every QUIET leg run-suites.sh runs, `<scene>-<lang>-<proto>`, read out of
    its `run "$proto" <scene>-<lang>` lines on the protocols the scene runs on."""
    import re
    out = set()
    for scene in QUIET:
        protos = ("wayland",) if scene in WAYLAND_ONLY else ("x11", "wayland")
        for stem in re.findall(r'^\s*run "\$proto" (' + re.escape(scene) + r'-[a-z]+) ',
                               run_suites, re.M):
            out.update(f"{stem}-{proto}" for proto in protos)
    return out


# THE CONTAINER'S CARGO TARGET IS A DOCKER VOLUME (docs/traps.md, the host
# out of memory under a matrix): written through the bind mount, 36.5 GB of
# build output landed in the host's tree and fed fseventsd. Only the
# recordings, which the host reads, stay on the bind mount; run-suites.sh
# refuses a target that is not a volume of its own.
TARGET_VOLUME = "kaya-linux-target"


def target_mounts(root):
    recordings = root / "target-linux/recordings"
    recordings.mkdir(parents=True, exist_ok=True)
    return ["-v", f"{TARGET_VOLUME}:/work/target-linux",
            "-v", f"{recordings}:/work/target-linux/recordings"]
