{-# LANGUAGE OverloadedStrings #-}

{- The grow conformance scene, Haskell port — see guests/rust/grow.rs.
   Every child of the column and of the row is a grower, so each split
   is exactly weight/Σweight: 1,2,1 divide the column 25/50/25 and the
   row's 1,3 divide its width 25/75.

   The textarea's handler is a no-op because 'textareaOn' is the only
   spelling this binding has. -}

import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    probe <- signal (T.pack "grow probe")
    one <- signal (T.pack "one")

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
