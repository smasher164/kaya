# GStreamer: a stop can lose the download thread's quit and join forever (2026-11-13)

A report ready to file at https://gitlab.freedesktop.org/gstreamer/gstreamer/-/issues
(it needs a GitLab account; docs/deferred.md holds the filing as an open item).
kaya's own record of the sighting is docs/traps.md, "The HLS stop that waited for
a download thread forever"; the probe is `gstreamer-hls-stop-hang-2026-11-13/hlsprobe.py`
beside this file.

---

**Title:** adaptivedemux2: downloadhelper_stop() hangs in g_thread_join() when the stop lands before the transfer thread enters g_main_loop_run()

**Versions:** GStreamer 1.28.7 (Debian forky, snapshot 20261005), with libsoup 3.6.6.
The same code is on `main` as of 2026-11-13 (`ext/adaptivedemux2/downloadhelper.c`).

**What happens.** A playbin3 playing an HLS stream (hlsdemux2) that is set to NULL
very soon after it reaches PAUSED can hang for good in the thread that called
set_state. The two stacks of a hung process:

- the stopping thread: `gst_hls_demux_change_state` -> `gst_adaptive_demux_change_state`
  -> `downloadhelper_stop` -> `g_thread_join` (downloadhelper.c:1068 on 1.28.7, :1110 on main)
- the transfer thread (`adaptive-downlo`): `dh_transfer_thread_func` -> `g_main_loop_run`
  -> `g_main_context_iterate` -> `ppoll` (downloadhelper.c:1017 on 1.28.7, :1059 on main)

**Why.** `downloadhelper_start()` creates the transfer thread, which pushes its
context and calls `g_main_loop_run (dh->loop)`. `downloadhelper_stop()` calls
`g_main_loop_quit (dh->loop)` and then joins the thread. If the stop runs after
`g_thread_try_new` but before the new thread has entered `g_main_loop_run`, the quit
only clears `is_running` on a loop that is not running yet; `g_main_loop_run` then
sets `is_running` to TRUE again on entry and polls forever, and the join never
returns. Nothing in the thread checks `dh->running` before it enters the loop.

**How to reproduce.** No application code is involved: a bare playbin3 with
fakesinks, on an fMP4 HLS stream served over plain HTTP from localhost.

```
python3 -m http.server 8799 &          # in a folder holding an fMP4 HLS stream
python3 hlsprobe.py http://127.0.0.1:8799/hls_fmp4.m3u8 700 1300 bare
```

Each try sets PAUSED, sleeps a random 0-40 ms, then sets NULL from another thread
and waits 15 s for it. With 8 busy-loop processes in the same Linux container to widen the
window, it hung 6 times in 700 tries, every time with the pair of stacks above.
(The same run also hits the libsoup abort that
gstreamer#5296 fixes for 1.28.8; that is a separate bug.)

Waiting before the stop until every adaptive demuxer's transfer thread is blocked in
poll does not close it from outside (3 hangs in 700): playbin3's streaming thread
can bring a new demuxer to PAUSED, and start its thread, between that check and
set_state(NULL).

**Suggested fix.** Make the quit impossible to lose, for example either:

1. post the quit into the loop rather than calling it from the outside, so it runs
   once the loop is running:

   ```c
   GSource *s = g_idle_source_new ();
   g_source_set_callback (s, (GSourceFunc) g_main_loop_quit_cb, dh->loop, NULL);
   g_source_attach (s, dh->transfer_context);
   g_source_unref (s);
   ```

   (with a small callback that calls `g_main_loop_quit` and returns
   `G_SOURCE_REMOVE`), or
2. in `dh_transfer_thread_func`, take `transfer_lock` and return without running
   the loop when `dh->running` is already FALSE.

---

## What kaya does meanwhile

Nothing in kaya closes it: a wait before kaya's own stop was tried and measured at
3 hangs in 700, so it was not kept. The matrix has seen it once, as a 60 s step
ceiling in media_delivery-rust-notsdemux-wayland, and tools/linux/stack-names.py now
names both frames in the leg's bundle.
