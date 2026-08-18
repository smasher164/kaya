-- The stall conformance scene, Haskell port — an app thread that stops
-- taking its occurrences is REPORTED.
--
-- THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE: `block` sleeps on
-- the app thread, and the scene asserts that kaya notices, then that the
-- queued click still arrives afterwards. `ping` is what makes work
-- PENDING while the app thread is gone, which is what the watchdog sees.
-- The blocking-release defect this scene was written for is in
-- docs/deferred.md (Haskell's `putMVar` release, now `tryPutMVar`).
--
-- See guests/rust/stall.rs and tools/scenes/stall.steps.

import Control.Concurrent (threadDelay)
import KayaApp
import KayaWire (Value (..))

-- Comfortably past the watchdog's one-second threshold, and short
-- enough that the leg is not paying for it. threadDelay counts
-- microseconds.
blockMicros :: Int
blockMicros = 2500000

-- A day, never a literal park (docs/traps.md, "The stall scene wedges
-- for a DAY"). threadDelay counts microseconds.
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
          -- DELIBERATELY WRONG, and the only place in this repo that is.
          -- Real work belongs on a thread of its own, posted back
          -- through `post`.
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
