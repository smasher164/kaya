-- The textarea conformance scene, Haskell port. See
-- guests/rust/textarea.rs and tools/scenes/textarea.steps.

import KayaApp
import KayaWire (Value (..), kindButton, kindColumn, kindLabel, kindTextarea)

lineTally :: String -> String
lineTally "" = "0 lines"
lineTally text = show (length (lines text)) ++ " lines"

main :: IO ()
main = kayaMain $ \app -> do
  (lineCount, editor, clearBtn) <- buildTx app $ do
    windowTitle "textarea"
    lineCount <- signal (VStr "0 lines")

    column <- widget kindColumn
    editor <- widget kindTextarea
    linesLabel <- widget kindLabel
    bindText linesLabel lineCount
    clearBtn <- widget kindButton
    setText clearBtn "clear"

    addChild column editor
    addChild column linesLabel
    addChild column clearBtn
    mount column
    return (lineCount, editor, clearBtn)

  onChange app editor $ \text ->
    submitTx app $ writeSignal lineCount (VStr (lineTally text))
  onClick app clearBtn $
    submitTx app $ do
      clearWidget editor
      focusWidget editor
