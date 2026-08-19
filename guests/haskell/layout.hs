{- The layout scene, Haskell port — the native-default observation
   vehicle; see guests/rust/layout.rs for the axes it stresses.

   THE SCENE ASSERTS NO GEOMETRY: container targets index by creation
   order, which legitimately differs per language. The grow contract is
   asserted in the grow scene instead. -}

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    probe <- signal (VStr "Layout probe")
    tailSig <- signal (VStr "tail")
    mixed <- signal (VStr "mixed")
    nested <- signal (VStr "nested")
    deep <- signal (VStr "deep")

    root <-
      column
        [ labelBound probe, -- label#0
          row
            [ buttonOn "A" (return ()),
              buttonOn "longer" (return ()),
              labelBound tailSig -- label#1
            ],
          row
            [ checkboxOn "check" (const (return ())),
              labelBound mixed, -- label#2
              sliderOn 0 1 0.5 (const (return ())) [Grow 1]
            ],
          row
            [ sliderOn 0 1 0.25 (const (return ())) [Grow 1],
              sliderOn 0 1 0.75 (const (return ())) [Grow 3]
            ],
          column
            [ labelBound nested, -- label#3
              row [labelBound deep, buttonOn "x" (return ())] -- label#4
            ]
        ]
    mount root
