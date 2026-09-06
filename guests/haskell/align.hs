-- The align scene, Haskell port — guests/rust/align.rs,
-- tools/scenes/align.steps.

import qualified Data.ByteString as BS
import KayaApp
import KayaWire (Value (..))

-- A 100x20 PNG: exact pixel widths, so row@wrapped breaks onto two lines
-- in every lane's window (docs/layout-knobs-plan.md §2).
widePng :: BS.ByteString
widePng =
  BS.pack
    [ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13,
      73, 72, 68, 82, 0, 0, 0, 100, 0, 0, 0, 20,
      8, 2, 0, 0, 0, 244, 162, 15, 194, 0, 0, 0,
      56, 73, 68, 65, 84, 120, 218, 237, 208, 1, 13, 0,
      0, 8, 3, 160, 7, 177, 164, 109, 141, 99, 133, 7,
      96, 35, 1, 153, 61, 74, 81, 32, 75, 150, 44, 89,
      178, 100, 41, 144, 37, 75, 150, 44, 89, 178, 20, 200,
      146, 37, 75, 150, 44, 89, 10, 122, 15, 34, 121, 229,
      167, 65, 55, 75, 87, 0, 0, 0, 0, 73, 69, 78,
      68, 174, 66, 96, 130
    ]

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
    plain <- signal (VStr "plain probe")

    root <-
      column
        [Align AlignStretch, A11yId "root"]
        [ -- the center trio
          column
            [Align AlignCenter, A11yId "centered"]
            [ labelBound probe, -- label#0
              buttonOn "mid" (return ()),
              -- the baseline trio
              row
                [Align AlignBaseline, A11yId "baseline"]
                [ labelBound base, -- label#1
                  buttonOn "tick" (return ()),
                  imageBytes tallPng
                ]
            ],
          -- row#1: the stretch pair's host
          row
            []
            [ labelBound anchor, -- label#2
              column
                [Grow 1, Align AlignStretch, A11yId "fitcol"]
                [ labelBound fit, -- label#3
                  buttonOn "wide" (return ())
                ]
            ],
          -- row@plain: NO align, so the core's centre default is what the
          -- scene reads
          row
            [A11yId "plain"]
            [ labelBound plain [A11yId "plainlabel"], -- label#4
              imageBytes tallPng
            ],
          -- column@knobs: NO align; fill opts one child out of its
          -- default and one in
          column
            [A11yId "knobs"]
            [ textarea [Fill False, A11yId "optout"],
              button "fills" [Fill True, A11yId "fills"],
              -- row@wrapped: six exact-width images flow onto two lines
              row
                [Wrap True, A11yId "wrapped"]
                (replicate 6 (imageBytes widePng))
            ]
        ]
    mount root
