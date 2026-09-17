{-# LANGUAGE OverloadedStrings #-}

-- The window scene, Haskell port — guests/rust/window.rs,
-- tools/scenes/window.steps.

import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    window primary [WTitle "window probe", WSize 640 400]
    probe <- signal (T.pack "window probe")

    root <-
      column
        []
        [ labelBound probe -- label#0
        ]
    mount root
