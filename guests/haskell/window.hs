-- The window scene, Haskell port — guests/rust/window.rs,
-- tools/scenes/window.steps.

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    window 0 [WTitle "window probe", WSize 640 400]
    probe <- signal (VStr "window probe")

    root <-
      column
        []
        [ labelBound probe -- label#0
        ]
    mount root
