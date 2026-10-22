# The window server's hit shape after a resize (2026-10-21)

Why: mac `music_search-python` failed twice at `choose segmented@chips 1`, 262 ms after
`resize_window 1100x720`, the app's AX hit test answering the menu bar for a point the tree's
radio group covered (docs/traps.md, the hit test that outran the resize).

Probe: an NSWindow at 594,211 of 560x600, `.accessory`, `orderFrontRegardless`; the main thread
runs NSApp; a second thread resizes to 1100x720 through `DispatchQueue.main.sync` as the harness
does, sleeps the delay, then in one more `main.sync` asks `AXUIElementCopyElementAtPosition` on
the app's element, `NSWindow.windowNumber(at:belowWindowWithWindowNumber: 0)` and
`CGWindowListCopyWindowInfo`'s bounds for the window, at a point 120 pt inside the new frame's
right edge (outside the old one). The probe has no main menu, so AppKit's menu-bar fallback
reads as kAXErrorNotImplemented (-25208) here and as AXMenuBar in the interpreter. The host was
idle (HIDIdleTime 24471 s); the maintainer's browser window lay under the probe's.

## A plain NSView

```
before any resize (560x600): appkit frame 594,274,560,632 server 594,274,560,632 | windowNumber(at:) 8520 [Firefox pid 1791 layer 0] | hit err -25208 
delay 0ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,560,632 | windowNumber(at:) 8520 [Firefox pid 1791 layer 0] | hit err -25208 
   server agreed with appkit after a further 17 ms
delay 5ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 11670 (ours) | hit err 0 AXWindow < AXApplication
   server agreed with appkit after a further 2 ms
delay 20ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 11670 (ours) | hit err 0 AXWindow < AXApplication
   server agreed with appkit after a further 1 ms
delay 50ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 11670 (ours) | hit err 0 AXWindow < AXApplication
   server agreed with appkit after a further 1 ms
delay 100ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 11670 (ours) | hit err 0 AXWindow < AXApplication
   server agreed with appkit after a further 1 ms
delay 250ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 11670 (ours) | hit err 0 AXWindow < AXApplication
   server agreed with appkit after a further 2 ms
delay 500ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 11670 (ours) | hit err 0 AXWindow < AXApplication
   server agreed with appkit after a further 2 ms
```

## A content view whose draw sleeps 300 ms

```
before any resize (560x600): appkit frame 594,274,560,632 server 593,273,562,634 | windowNumber(at:) 8520 [Firefox pid 1791 layer 0] | hit err -25208 
delay 0ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 8520 [Firefox pid 1791 layer 0] | hit err -25208 
   server agreed with appkit after a further 0 ms
delay 5ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 8520 [Firefox pid 1791 layer 0] | hit err -25208 
   server agreed with appkit after a further 0 ms
delay 20ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 8520 [Firefox pid 1791 layer 0] | hit err -25208 
   server agreed with appkit after a further 0 ms
delay 50ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 8520 [Firefox pid 1791 layer 0] | hit err -25208 
   server agreed with appkit after a further 0 ms
delay 100ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 8520 [Firefox pid 1791 layer 0] | hit err -25208 
   server agreed with appkit after a further 0 ms
delay 250ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 8520 [Firefox pid 1791 layer 0] | hit err -25208 
   server agreed with appkit after a further 0 ms
delay 500ms after setContentSize(1100x720): appkit frame 594,274,1100,752 server 594,274,1100,752 | windowNumber(at:) 11679 (ours) | hit err 0 AXWindow < AXApplication
   server agreed with appkit after a further 0 ms
```

Reading: the server's bounds moved with setContentSize (0 ms in the second run, 17 ms in the
first) while the shape the server hit-tests moved with the first frame drawn at the new size
(between 250 and 500 ms with the slow draw). `windowNumber(at:)` answered Firefox's window
beneath for the point meanwhile, and the hit test refused.

## The gate's probe, standalone (tools/checks/swiftui-resize-shape.swift)

Three runs each, the time `kayaAwaitResizeShape` took to see the server's shape cover the three
corners a 120x80 -> 240x160 growth brought in: slow draw 326, 329, 329 ms; plain view 15, 16,
13 ms. The gate asserts no duration, only the order (not covered inside the resize's own
main-thread block, covered after the wait).

## The leg's own line

tools/run-leg.py music_search python, first build: `resize shape: 3000 ms after the resize the
window server still holds 3 of 3 corner(s) ... held by window 8520 of Firefox` with the choose
passing, which is how the reader learned to walk the z-order down to this window (AppKit's hit
test reads the app's own windows' shapes). After the rework: `the window server's shape of window
11868 covered all 3 corner(s) the resize brought in after 6 ms, with up to 1 window(s) of other
applications above it there`.
