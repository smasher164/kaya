{- The grow conformance scene, Haskell port — see guests/rust/grow.rs
   for the full rationale. Every child of the column and of the row is
   a grower, so each split is exactly weight/Σweight: 1,1,2 divide the
   column 25/25/50 and the row's 1,3 divide its width 25/75. The
   harness (KAYA_SELFTEST=grow) asserts both splits plus root-fills,
   byte-for-byte against every other language and backend.

   'grow' is the declarative combinator; 'setGrow' is the dynamic path
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
        [ grow 1 (labelBound probe), -- label#0
          grow 1 (buttonOn "quarter" (return ())),
          grow
            2
            ( row
                [ grow 1 (labelBound one), -- label#1
                  grow 3 (buttonOn "three" (return ()))
                ]
            )
        ]
    mount root
