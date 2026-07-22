-- The radio conformance scene, Haskell port. See
-- guests/rust/radio.rs and tools/scenes/radio.steps.

import KayaApp
import KayaWire (Value (..))

options :: [String]
options = ["Small", "Medium", "Large"]

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    windowTitle "radio"
    size <- signal (VStr "size: Small")

    let onPick index =
          submitTx app $
            writeSignal size (VStr ("size: " ++ options !! index))

    root <-
      column
        []
        [ radioOn options 0 onPick,
          labelBound size -- label#0
        ]
    mount root
    return ()
  return ()
