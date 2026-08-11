{- The grow conformance scene, Haskell port — see guests/rust/grow.rs
   for the full rationale. Every child of the column and of the row is
   a grower, so each split is exactly weight/Σweight: 1,2,1 divide the
   column 25/50/25 and the row's 1,3 divide its width 25/75. The
   harness (KAYA_SELFTEST=grow) asserts both splits, root-fills, and
   that the textarea TAKES the track its weight earned, byte-for-byte
   against every other language and backend.

   The textarea's handler is the no-op this scene gives its buttons:
   'textareaOn' is the only spelling the binding has (every other
   language can declare one without a handler), and nothing here types
   into it. -}

{- 'grow' is the declarative combinator; 'setGrow' is the dynamic path
   this scene has no reason to use. -}

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
