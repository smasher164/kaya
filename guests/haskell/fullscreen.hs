{-# LANGUAGE OverloadedStrings #-}

-- The fullscreen scene, Haskell port — guests/rust/fullscreen.rs,
-- tools/scenes/fullscreen.steps. The app keeps its own copy of the state: a
-- toggle writes @not on@, and the user's door moves the copy through
-- 'WOnFullscreenChanged'.

import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  on <- newIORef False
  pinged <- newIORef (0 :: Int)
  buildTx app $ do
    asked <- signalText "windowed"
    user <- signalText "no change from the user"
    pings <- signalText "pings 0"

    window
      primary
      [ WTitle "fullscreen",
        WOnFullscreenChanged
          ( \now -> do
              writeIORef on now
              submitTx app $
                writeSignal user
                  (if now then "the user turned fullscreen on" else "the user turned fullscreen off")
          )
      ]

    root <-
      column
        []
        [ labelBound asked, -- label#0
          labelBound user, -- label#1
          labelBound pings, -- label#2
          buttonOn "toggle fullscreen" -- button#0
            ( do
                modifyIORef' on not
                now <- readIORef on
                submitTx app $ do
                  window primary [WFullscreen now]
                  writeSignal asked (if now then "asked for fullscreen" else "asked for a window")
            ),
          buttonOn "ping" -- button#1
            ( do
                modifyIORef' pinged (+ 1)
                n <- readIORef pinged
                submitTx app $ writeSignal pings ("pings " <> tshow n)
            )
        ]
    mount root
