{- The gallery scene from Haskell: a row with a checkbox and its
   status label, and a row with a slider and its volume label. Both
   controls own their state and report each change; the app answers by
   writing the paired signal — the entry's uncontrolled contract, with
   a Bool and a Double.

   Build like milestone2.hs, then run with KAYA_SELFTEST=gallery. -}

import KayaApp
import KayaWire (Value (..))

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
          row [sliderOn 0 1 0.5 onVolume, labelBound volume]
        ]
    mount root
