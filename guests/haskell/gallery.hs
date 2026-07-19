{- The gallery scene from Haskell: a row with a checkbox and its
   status label, and a row with a slider and its volume label. Both
   controls own their state and report each change; the app answers by
   writing the paired signal — the entry's uncontrolled contract, with
   a Bool and a Double.

   Build like milestone2.hs, then run with KAYA_SELFTEST=gallery. -}

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC

import KayaApp
import KayaWire (Value (..))

{- A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the first
   binary asset, embedded as source per the include_str! doctrine —
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
  -- The construction sugar: constructors carry their handlers,
  -- containers take their children, and the do-block reads as the
  -- tree.
  buildTx app $ do
    status <- signal (VStr "urgent: false")
    volume <- signal (VStr "volume: 50%")

    let onUrgent checked =
          submitTx app $
            writeSignal status
              (VStr ("urgent: " ++ if checked then "true" else "false"))
        onVolume v =
          -- Integer percent, so every language's formatting agrees.
          submitTx app $
            writeSignal volume
              (VStr ("volume: " ++ show (round (v * 100) :: Int) ++ "%"))

    root <-
      column
        [ row [checkboxOn "urgent" onUrgent, labelBound status],
          row [sliderOn 0 1 0.5 onVolume, labelBound volume],
          {- The content-buffer row: a valid 2x2 PNG decodes and
             reports its size, and deliberately invalid bytes read 0x0
             — decode failure is the placeholder class, never a crash,
             on every backend. -}
          row [imageBytes testPng, imageBytes (BC.pack "not an image")]
        ]
    mount root
