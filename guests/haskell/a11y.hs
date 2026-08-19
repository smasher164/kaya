{- The accessibility conformance scene from Haskell: the two universal
   props (the 'A11yId' and 'A11yLabel' attrs), read back out of the
   PLATFORM'S OWN accessibility tree rather than kaya's model.

   EXACTLY ONE container of each container kind: container targets are
   ordinal. See guests/rust/a11y.rs; the byte-frozen contract is
   tools/scenes/a11y.steps. -}

import KayaApp

-- The one the mark is under: the picture this app's own BUILD shipped.
markName :: String
markName = "images/a11y-logo.png"

main :: IO ()
main = kayaMain $ \app -> do
  -- Out here rather than below: Build is a pure state monad, so the
  -- asset is opened in the IO around the transaction. THE BYTES NEVER
  -- ENTER THIS GUEST'S HEAP — the handle goes to the blob channel.
  mark <- asset markName
  _ <- buildTx app $ do
    root <-
      column
        [A11yId "form", A11yLabel "Form"]
        [ -- Caption-bearing controls: identified, but deliberately NOT
          -- labelled. The platform must speak the caption.
          buttonOn "Save" (return ()) [A11yId "save", A11yHint "save the draft"],
          checkboxOn "Details" (const (return ()))
            [A11yId "details", A11yHint "show more detail"],
          buttonOn "Reset" (return ()) [A11yId "reset"],
          labelText "Ready" [A11yId "status"],
          -- Caption-less controls: an app MUST name these, and the tree
          -- must report the authored name.
          entryOn (const (return ())) [A11yId "name", A11yLabel "Full name"],
          textareaOn (const (return ())) [A11yId "notes", A11yLabel "Notes"],
          sliderOn 0 1 0.5 (const (return ())) [A11yId "volume", A11yLabel "Volume"],
          progress 0.25 [A11yId "loading", A11yLabel "Loading"],
          imageAsset mark [A11yId "logo", A11yLabel "Logo"],
          selectOn ["Red", "Green"] 0 (const (return ()))
            [A11yId "color", A11yLabel "Color"],
          radioOn ["Small", "Large"] 0 (const (return ()))
            [A11yId "size", A11yLabel "Size"],
          -- grid takes no attr list (the one container constructor that
          -- does not), so its props ride the Build monad: declare it,
          -- set the props as statements, hand the handle back.
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
            ]
        ]
    mount root
    return ()
  -- Safe here: the blob table already holds its own reference.
  assetClose mark
  return ()
