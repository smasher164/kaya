{-# LANGUAGE OverloadedStrings #-}

-- The textarea scene, Haskell port — guests/rust/textarea.rs,
-- tools/scenes/textarea.steps.

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

lineTally :: Text -> Text
lineTally text
  | T.null text = "0 lines"
  | otherwise = T.pack (show (length (T.lines text)) ++ " lines")

main :: IO ()
main = kayaMain $ \app -> do
  (lineCount, editor, clearBtn) <- buildTx app $ do
    window primary [WTitle "textarea"]
    lineCount <- signal (T.pack "0 lines")

    -- Realized here because the handlers below need their handles.
    editor <- textarea
    clearBtn <- button "clear"
    root <- column [] [pure editor, labelBound lineCount, pure clearBtn]
    mount root
    return (lineCount, editor, clearBtn)

  onChange app editor $ \text ->
    submitTx app $ writeSignal lineCount (lineTally text)
  onClick app clearBtn $
    submitTx app $ do
      clearWidget editor
      focusWidget editor
