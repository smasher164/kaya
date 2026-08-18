{- The grow conformance scene, Haskell port — see guests/rust/grow.rs
   for the full rationale. Every child of the column and of the row is a
   grower, so each split is exactly weight/Σweight: 1,2,1 divide the
   column 25/50/25 and the row's 1,3 divide its width 25/75.

   The textarea's handler is a no-op because 'textareaOn' is the only
   spelling this binding has; nothing here types into it. -}

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    probe <- signal (VStr "grow probe")
    one <- signal (VStr "one")

    root <-
      column
        [ labelBound probe [Grow 1], -- label#0
          textareaOn (\_ -> return ()) [Grow 2], -- textarea#0
          row
            [Grow 1, Spacing 12]
            [ labelBound one [Grow 1], -- label#1
              buttonOn "three" (return ()) [Grow 3]
            ]
        ]
    mount root
