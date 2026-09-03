-- The stall scene, Haskell port — guests/rust/stall.rs,
-- tools/scenes/stall.steps.

import Control.Concurrent (threadDelay)
import KayaApp
import KayaWire (Value (..))

-- Past the watchdog's one-second threshold; threadDelay counts microseconds.
blockMicros :: Int
blockMicros = 2500000

-- A day, never a literal park (docs/traps.md, the stall scene wedges for a DAY).
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
