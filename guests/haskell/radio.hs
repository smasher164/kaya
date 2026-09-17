{-# LANGUAGE OverloadedStrings #-}

-- The radio scene, Haskell port — guests/rust/radio.rs,
-- tools/scenes/radio.steps.

import Data.Text (Text)
import KayaApp

options :: [Text]
options = ["Small", "Medium", "Large"]

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window primary [WTitle "radio"]
    size <- signalText "size: Small"

    let onPick index =
          submitTx app $
            writeSignal size ("size: " <> options !! index)

    root <-
      column
        []
        [ radioOn options 0 onPick,
          labelBound size -- label#0
        ]
    mount root
    return ()
  return ()
