"""The Linux lane's tables (tools/linux/run-suites.sh reads them through
tools/linux/scene-mods.py). `MODS` has the phone lanes' drop grammar
(tools/lib/scene_cut.py): a TUPLE OF BLOCKS, each (step specs, keep,
reason), each spec a leading run of words naming exactly one step."""

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
}

# The scenes whose legs run on the wayland slots alone, each with the reason
# tools/linux/scene-mods.py --protocols prints for the x11 legs not run.
WAYLAND_ONLY = {
    "fullscreen": "Xvfb runs no window manager, and gtk_window_fullscreen asks "
                  "one through _NET_WM_STATE: measured doing nothing there "
                  "(docs/fullscreen-plan.md §4.2)",
}
