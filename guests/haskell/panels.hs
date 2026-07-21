-- The panels conformance scene, Haskell port — the auxiliary-window
-- grammar via the config-list spelling. See guests/rust/panels.rs
-- and tools/scenes/panels.steps.

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    windowTitle "panels"
    s <- signal (VStr "two panels")

    root <- column [] [labelBound s] -- label#0
    mount root

    createWindow 1 [WTitle "inspector", WSize 480 320, WVetoClose True]
    caption <- signal (VStr "inspector pane")
    aux <- column [] [labelBound caption] -- label#1
    mountIn 1 aux
    return s

  onCloseRequested app $ \window ->
    buildTx app $ do
      writeSignal status (VStr "close requested")
      destroyWindow window
