-- The panels scene, Haskell port — guests/rust/panels.rs,
-- tools/scenes/panels.steps.

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    window 0 [WTitle "panels"]
    s <- signal (VStr "two panels")

    root <- column [] [labelBound s] -- label#0
    mount root

    createWindow
      1
      [ WTitle "inspector",
        WSize 480 320,
        WVetoClose True,
        WOnCloseRequested
          ( buildTx app $ do
              writeSignal s (VStr "close requested")
              destroyWindow 1
          )
      ]
    caption <- signal (VStr "inspector pane")
    aux <- column [] [labelBound caption] -- label#1
    mountIn 1 aux
    return s

  _ <- return status
  return ()
