{-# LANGUAGE OverloadedStrings #-}

-- The a11y scene, Haskell port — guests/rust/a11y.rs, tools/scenes/a11y.steps.

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

markName :: String
markName = "images/a11y-logo.png"

main :: IO ()
main = kayaMain $ \app -> do
  -- Out here: Build is a pure state monad, so the asset is opened in the IO
  -- around the transaction.
  mark <- asset markName
  _ <- buildTx app $ do
    spoken <- signal (T.pack "Before")
    root <-
      column
        [A11yId ("form" :: Text), A11yLabel ("Form" :: Text)]
        [ -- Deliberately not labelled: the platform must speak the
          -- caption.
          buttonOn "Save" (return ()) [A11yId ("save" :: Text), A11yHint ("save the draft" :: Text)],
          checkboxOn "Details" (const (return ()))
            [A11yId ("details" :: Text), A11yHint ("show more detail" :: Text)],
          buttonOn "Reset" (return ()) [A11yId ("reset" :: Text)],
          labelText "Ready" [A11yId ("status" :: Text)],
          entryOn (const (return ())) [A11yId ("name" :: Text), A11yLabel ("Full name" :: Text)],
          textareaOn (const (return ())) [A11yId ("notes" :: Text), A11yLabel ("Notes" :: Text)],
          sliderOn 0 1 0.5 (const (return ())) [A11yId ("volume" :: Text), A11yLabel ("Volume" :: Text)],
          progress 0.25 [A11yId ("loading" :: Text), A11yLabel ("Loading" :: Text)],
          imageAsset mark [A11yId ("logo" :: Text), A11yLabel ("Logo" :: Text)],
          selectOn ["Red", "Green"] 0 (const (return ()))
            [A11yId ("color" :: Text), A11yLabel ("Color" :: Text)],
          radioOn ["Small", "Large"] 0 (const (return ()))
            [A11yId ("size" :: Text), A11yLabel ("Size" :: Text)],
          -- grid takes no attr list, the one container constructor that does
          -- not, so its props ride the Build monad.
          ( do
              cells <- grid 2 [labelText "Name", labelText "Ada"]
              setA11yId cells "cells"
              setA11yLabel cells "Cells"
              return cells
          ),
          scroll [A11yId ("feed" :: Text), A11yLabel ("Feed" :: Text)] (labelText "Item"),
          row
            [A11yId ("actions" :: Text), A11yLabel ("Actions" :: Text)]
            [ buttonOn "Cancel" (return ()) [A11yId ("cancel" :: Text)],
              buttonOn "OK" (return ()) [A11yId ("ok" :: Text)]
            ],
          labelText "Spoken" [A11yId ("spoken" :: Text), A11yLabel spoken],
          buttonOn
            "Rename"
            (buildTx app (writeSignal spoken (T.pack "After")) >> return ())
            [A11yId ("rename" :: Text)]
        ]
    mount root
    return ()
  -- Safe: the blob table already holds its own reference.
  assetClose mark
  return ()
