{- The accessibility conformance scene from Haskell: the two universal
   props (the 'A11yId' and 'A11yLabel' attrs) and the verb that reads
   them back out of the PLATFORM'S OWN accessibility tree rather than
   kaya's model.

   Every widget kind appears, and exactly one container of each
   container kind — the props are universal, and container targets are
   stable only while a scene keeps one of each. See guests/rust/a11y.rs
   for the full note; the byte-frozen contract is
   tools/scenes/a11y.steps.

   The attrs are indexed by widget class and these two are polymorphic
   in it (Attr c, like 'Grow'), which is the type-level statement that
   they are UNIVERSAL: a leaf and a box take them the same way. -}

import qualified Data.ByteString as BS

import KayaApp

{- A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the gallery
   scene's asset, embedded as source per the include_str! doctrine —
   scenes carry their inputs, no runtime file I/O. -}
testPng :: BS.ByteString
testPng =
  BS.pack
    [ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
      0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115,
      0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192,
      0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139,
      0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130
    ]

main :: IO ()
main = kayaMain $ \app -> do
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
          imageBytes testPng [A11yId "logo", A11yLabel "Logo"],
          -- The two CHOICE kinds: their options carry captions, the
          -- choice itself does not.
          selectOn ["Red", "Green"] 0 (const (return ()))
            [A11yId "color", A11yLabel "Color"],
          radioOn ["Small", "Large"] 0 (const (return ()))
            [A11yId "size", A11yLabel "Size"],
          -- Containers are GROUPS to an assistive client, and naming
          -- one is how an app declares it a group.
          -- grid takes no attr list (the one container constructor
          -- that does not), so its props ride the Build monad — the
          -- same shape the gallery scene uses for bindValue.
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
  return ()
