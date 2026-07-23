-- The panels conformance scene, Haskell port — the auxiliary-window
-- grammar via the config-list spelling. See guests/rust/panels.rs
-- and tools/scenes/panels.steps.

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    window 0 [WTitle "panels"]
    s <- signal (VStr "two panels")

    root <- column [] [labelBound s] -- label#0
    mount root

    -- The veto handler binds to the inspector at its declaration
    -- (handlers scope to the thing that creates them): it can only
    -- ever mean this window's close.
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

  -- The handler rides the declaration above; nothing app-global
  -- remains.
  _ <- return status
  return ()
