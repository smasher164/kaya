-- The textarea conformance scene, Haskell port. See
-- guests/rust/textarea.rs and tools/scenes/textarea.steps.

import KayaApp
import KayaWire (Value (..))

lineTally :: String -> String
lineTally "" = "0 lines"
lineTally text = show (length (lines text)) ++ " lines"

main :: IO ()
main = kayaMain $ \app -> do
  (lineCount, editor, clearBtn) <- buildTx app $ do
    window 0 [WTitle "textarea"]
    lineCount <- signal (VStr "0 lines")

    -- Realized here because the handlers below need their handles;
    -- `pure` then places each in the column at the position every other
    -- language puts it.
    editor <- textarea
    clearBtn <- button "clear"
    root <- column [] [pure editor, labelBound lineCount, pure clearBtn]
    mount root
    return (lineCount, editor, clearBtn)

  onChange app editor $ \text ->
    submitTx app $ writeSignal lineCount (VStr (lineTally text))
  onClick app clearBtn $
    submitTx app $ do
      clearWidget editor
      focusWidget editor
