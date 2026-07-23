-- The select conformance scene, Haskell port. See
-- guests/rust/select.rs and tools/scenes/select.steps.

import KayaApp
import KayaWire (Value (..))

options :: [String]
options = ["Red", "Green", "Blue"]

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window 0 [WTitle "select"]
    picked <- signal (VStr "picked: Red")

    let onPick index =
          submitTx app $
            writeSignal picked (VStr ("picked: " ++ options !! index))

    root <-
      column
        []
        [ selectOn options 0 onPick,
          labelBound picked -- label#0
        ]
    mount root
    return ()
  return ()
