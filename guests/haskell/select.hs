{-# LANGUAGE OverloadedStrings #-}

-- The select scene, Haskell port — guests/rust/select.rs,
-- tools/scenes/select.steps.

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

options :: [Text]
options = ["Red", "Green", "Blue"]

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window primary [WTitle "select"]
    picked <- signal (T.pack "picked: Red")

    let onPick index =
          submitTx app $
            writeSignal picked ("picked: " <> options !! index)

    root <-
      column
        []
        [ selectOn options 0 onPick,
          labelBound picked -- label#0
        ]
    mount root
    return ()
  return ()
