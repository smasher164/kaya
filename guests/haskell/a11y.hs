-- The a11y scene, Haskell port — guests/rust/a11y.rs, tools/scenes/a11y.steps.

import KayaApp
import KayaWire (Value (..))

markName :: String
markName = "images/a11y-logo.png"

main :: IO ()
main = kayaMain $ \app -> do
  -- Out here: Build is a pure state monad, so the asset is opened in the IO
  -- around the transaction.
  mark <- asset markName
  _ <- buildTx app $ do
    spoken <- signal (VStr "Before")
    root <-
      column
        [A11yId "form", A11yLabel "Form"]
        [ -- Deliberately not labelled: the platform must speak the
          -- caption.
          buttonOn "Save" (return ()) [A11yId "save", A11yHint "save the draft"],
          checkboxOn "Details" (const (return ()))
            [A11yId "details", A11yHint "show more detail"],
          buttonOn "Reset" (return ()) [A11yId "reset"],
          labelText "Ready" [A11yId "status"],
          entryOn (const (return ())) [A11yId "name", A11yLabel "Full name"],
          textareaOn (const (return ())) [A11yId "notes", A11yLabel "Notes"],
          sliderOn 0 1 0.5 (const (return ())) [A11yId "volume", A11yLabel "Volume"],
          progress 0.25 [A11yId "loading", A11yLabel "Loading"],
          imageAsset mark [A11yId "logo", A11yLabel "Logo"],
          selectOn ["Red", "Green"] 0 (const (return ()))
            [A11yId "color", A11yLabel "Color"],
          radioOn ["Small", "Large"] 0 (const (return ()))
            [A11yId "size", A11yLabel "Size"],
          -- grid takes no attr list, the one container constructor that does
          -- not, so its props ride the Build monad.
          ( do
              cells <- grid 2 [labelText "Name", labelText "Ada"]
              setA11yId cells "cells"
              setA11yLabel cells "Cells"
              return cells
          ),
          scroll [A11yId "feed", A11yLabel "Feed"] (labelText "Item"),
          row
            [A11yId "actions", A11yLabel "Actions"]
            [ buttonOn "Cancel" (return ()) [A11yId "cancel"],
              buttonOn "OK" (return ()) [A11yId "ok"]
            ],
          labelText "Spoken" [A11yId "spoken", A11yLabel spoken],
          buttonOn
            "Rename"
            (buildTx app (writeSignal spoken (VStr "After")) >> return ())
            [A11yId "rename"]
        ]
    mount root
    return ()
  -- Safe: the blob table already holds its own reference.
  assetClose mark
  return ()
