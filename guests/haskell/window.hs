-- The window conformance scene, Haskell port — see
-- guests/rust/window.rs and tools/scenes/window.steps. The primary
-- surface's props as assertions: the title must materialize in the
-- real title bar, the advisory 640x400 request must be honored on a
-- desktop.

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    windowTitle "window probe"
    windowSize 640 400
    probe <- signal (VStr "window probe")

    root <-
      column
        []
        [ labelBound probe -- label#0
        ]
    mount root
