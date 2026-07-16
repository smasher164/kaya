{- The gallery scene from Haskell: a row container laying a checkbox
   and the status label side by side. The box owns its checked bit and
   reports each flip through onToggle; the app answers by writing the
   status signal — the same uncontrolled contract as the entry, with a
   bool.

   Build like milestone2.hs, then run with KAYA_SELFTEST=gallery. -}

import KayaApp
import KayaWire (Value (..), kindCheckbox, kindColumn, kindLabel, kindRow)

main :: IO ()
main = kayaMain $ \app -> do
  (status, urgent) <- buildTx app $ do
    status <- signal (VStr "urgent: false")

    column <- widget kindColumn
    row <- widget kindRow
    urgent <- widget kindCheckbox
    setText urgent "urgent"
    statusLabel <- widget kindLabel
    bindText statusLabel status

    addChild row urgent
    addChild row statusLabel
    addChild column row
    mount column
    return (status, urgent)

  onToggle app urgent $ \checked ->
    submitTx app $
      writeSignal status (VStr ("urgent: " ++ if checked then "true" else "false"))
