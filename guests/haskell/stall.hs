-- The stall conformance scene, Haskell port — an app thread that stops
-- taking its occurrences is REPORTED (DESIGN.md, Threading model and
-- protocol).
--
-- THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, in every
-- language. Every other guest keeps blocking work off the app thread —
-- each of the eight filedialog guests carries a paragraph explaining
-- why its read goes to a worker — and that discipline was entirely
-- unenforced. Nothing would have told anyone that a guest ignoring it
-- had wedged the app. The class is not hypothetical, and THIS language
-- is where it bit: a Haskell release once used `putMVar`, which blocks
-- when the MVar is full, so a second click would have blocked the app
-- thread forever. The scene clicked once, so no gate saw it; it was
-- found by asking whether Go's `close` blocks.
--
-- So `block` does exactly the forbidden thing — it sleeps on the app
-- thread — and the scene asserts that kaya NOTICES. A scene that merely
-- timed out would prove the app was broken; this proves the framework
-- reported it, which is the whole feature.
--
-- WHY THE SECOND CLICK MATTERS: the consumer cursor advances BEFORE a
-- record reaches the guest, so a handler blocking on an empty queue
-- looks exactly like an idle app — and nothing is waiting on it, so it
-- may as well be. `ping` is what makes work PENDING while the app
-- thread is gone. That is what the watchdog can see, and it is what a
-- person reports: they click, and click again, and nothing happens.
--
-- The recovery is asserted too: the blocked handler returns, the queued
-- click is taken, and the label shows it — so the watchdog reported a
-- stall rather than a death, and nothing was dropped.
--
-- AND THEN ONE THAT NEVER COMES BACK. A handler blocking for 2.5
-- seconds is a SLOW handler, and every assertion above would pass for
-- one; a real deadlock does not politely end. `wedge` never returns, so
-- the scene ends there — and the leg still reports its verdict, because
-- the harness runs on its own thread and asks the MAIN thread to exit.
-- Neither path needs the app thread that is gone.
--
-- See guests/rust/stall.rs and tools/scenes/stall.steps.

import Control.Concurrent (threadDelay)
import KayaApp
import KayaWire (Value (..))

-- Comfortably past the watchdog's one-second threshold, and short
-- enough that the leg is not paying for it: the scene asserts the stall
-- and then the recovery, so this is the whole cost. threadDelay counts
-- microseconds.
blockMicros :: Int
blockMicros = 2500000

-- AND ONE THAT NEVER COMES BACK, which is the shape a real deadlock
-- has. A day rather than a literal park, because "forever" is spelled
-- differently in all eight languages and some of those spellings wake
-- their runtime's own deadlock detector; within a leg that lasts
-- seconds, a day and forever are the same thing. The process exits out
-- from under it.
wedgeMicros :: Int
wedgeMicros = 86400 * 1000000

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window 0 [WTitle "stall"]
    status <- signal (VStr "ready")

    root <-
      column
        []
        [ labelBound status [A11yId "status"], -- label#0
          -- DELIBERATELY WRONG, and the only place in this repo that
          -- is. Anything real belongs on a thread of its own with the
          -- result posted back through `post` — which is what every
          -- other guest does, and what the watchdog's own message tells
          -- you to do.
          buttonOn
            "block" -- button#0
            (threadDelay blockMicros)
            [],
          buttonOn
            "ping" -- button#1
            (buildTx app (writeSignal status (VStr "pinged")))
            [],
          buttonOn
            "wedge" -- button#2
            (threadDelay wedgeMicros)
            []
        ]
    mount root
    return ()
  return ()
