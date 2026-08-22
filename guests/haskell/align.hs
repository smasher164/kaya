{- The align conformance scene, Haskell port — see guests/rust/align.rs
   and tools/scenes/align.steps for the full rationale. The row's tall
   no-baseline image has its BOTTOM on the baseline (the CSS
   replaced-element rule); that construction is what separates the modes
   on every platform's control metrics. row#1 hosts the grown, stretched
   nested column the ruling pins (docs/deferred.md, the nested-container
   GAP). -}

import qualified Data.ByteString as BS
import KayaApp
import KayaWire (Value (..))

-- A 2x64 PNG: the tall no-baseline child.
tallPng :: BS.ByteString
tallPng =
  BS.pack
    [ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13,
      73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 64,
      8, 2, 0, 0, 0, 191, 68, 49, 20, 0, 0, 0,
      18, 73, 68, 65, 84, 120, 156, 99, 8, 8, 138, 2,
      34, 134, 81, 106, 104, 82, 0, 67, 50, 126, 1, 49,
      1, 65, 124, 0, 0, 0, 0, 73, 69, 78, 68, 174,
      66, 96, 130
    ]

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    probe <- signal (VStr "align probe")
    base <- signal (VStr "base")
    anchor <- signal (VStr "anchor")
    fit <- signal (VStr "fit")

    root <-
      column
        [Align AlignStretch, A11yId "root"]
        [ -- the center trio
          column
            [Align AlignCenter, A11yId "centered"]
            [ labelBound probe, -- label#0
              buttonOn "mid" (return ()),
              -- row#0: the baseline trio
              row
                [Align AlignBaseline]
                [ labelBound base, -- label#1
                  buttonOn "tick" (return ()),
                  imageBytes tallPng
                ]
            ],
          -- row#1: the stretch pair's host
          row
            []
            [ labelBound anchor, -- label#2
              -- grown into the row's leftover, stretched across its
              -- own breadth
              column
                [Grow 1, Align AlignStretch, A11yId "fitcol"]
                [ labelBound fit, -- label#3
                  buttonOn "wide" (return ())
                ]
            ]
        ]
    mount root
