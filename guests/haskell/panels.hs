{-# LANGUAGE OverloadedStrings #-}

-- The panels scene, Haskell port — guests/rust/panels.rs,
-- tools/scenes/panels.steps.

import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    window primary [WTitle "panels"]
    s <- signal (T.pack "two panels")

    root <- column [] [labelBound s] -- label#0
    mount root

    createWindow
      1
      [ WTitle "inspector",
        WSize 480 320,
        WVetoClose True,
        WOnCloseRequested
          ( buildTx app $ do
              writeSignal s (T.pack "close requested")
              destroyWindow 1
          )
      ]
    caption <- signal (T.pack "inspector pane")
    aux <- column [] [labelBound caption] -- label#1
    mountIn 1 aux
    return s

  _ <- return status
  return ()
