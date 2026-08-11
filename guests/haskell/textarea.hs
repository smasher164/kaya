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

    -- THE EDITOR AND THE BUTTON REALIZE HERE because the handlers below
    -- need their handles; `pure` then places each in the column at the
    -- position every other language puts it (the clipboard scene's
    -- idiom).
    --
    -- This scene used to be built entirely at the widget-kind floor —
    -- `widget kindColumn`, `addChild`, `setText` — while `textarea`,
    -- `button`, `labelBound` and `column` all sat in the binding unused.
    -- Nothing caught it: check-sugar-surface's floor rules read only the
    -- two carve-out scenes, so a guest outside that table could teach
    -- the floor indefinitely. tools/guest-floor.py is the sweep that
    -- would have, and does now.
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
