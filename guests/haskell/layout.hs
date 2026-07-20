{- The layout scene, Haskell port — the native-default observation
   vehicle; see guests/rust/layout.rs for the axes it stresses. The two
   label expects (KAYA_SELFTEST=layout) only prove the tree built; the
   scene asserts no geometry — container targets index by creation
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
          -- Main-axis free space: three unequal children with leftover
          -- room.
          row
            [ buttonOn "A" (return ()),
              buttonOn "longer" (return ()),
              labelBound tailSig -- label#1
            ],
          -- Cross-axis alignment: three different intrinsic heights,
          -- one grower filling the leftover row width.
          row
            [ checkboxOn "check" (const (return ())),
              labelBound mixed, -- label#2
              grow 1 (sliderOn 0 1 0.5 (const (return ())))
            ],
          -- Proportional grow: two growers of unequal weight in one
          -- row.
          row
            [ grow 1 (sliderOn 0 1 0.25 (const (return ()))),
              grow 3 (sliderOn 0 1 0.75 (const (return ())))
            ],
          -- Nesting: a column inside the root column, a row inside
          -- that.
          column
            [ labelBound nested, -- label#3
              row [labelBound deep, buttonOn "x" (return ())] -- label#4
            ]
        ]
    mount root
