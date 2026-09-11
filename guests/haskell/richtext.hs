-- The rich text scene, Haskell port — guests/rust/richtext.rs,
-- tools/scenes/richtext.steps. THE OFFSETS ARE UTF-8 BYTES; the é in the
-- first word is what makes a UTF-16 reader fail (docs/ranges-units.md).

import Data.List (intercalate)

import KayaApp
import KayaWire (Value (..))

docSource :: String
docSource = "Héllo world\nSecond line"

-- The core's spelling of runs (`expect_runs`), so the binding's document
-- and the core's mirror are compared as one string.
spell :: [Run] -> String
spell = intercalate "|" . map one
  where
    one r
      | runValue r == "true" = span_ r ++ runName r
      | otherwise = span_ r ++ runName r ++ "=" ++ runValue r
    span_ r = show (runStart r) ++ ":" ++ show (runEnd r) ++ " "

main :: IO ()
main = kayaMain $ \app -> do
  (editor, lastAct, runs) <- buildTx app $ do
    window 0 [WTitle "richtext"]
    lastAct <- signal (VStr "")
    runs <- signal (VStr "")

    -- Realized here because the handlers below need their handles.
    editor <- textarea [Rich True, A11yId "doc", A11yLabel "Document"]
    root <-
      column
        []
        [ pure editor, -- textarea#0
          labelBound lastAct, -- label#0
          labelBound runs, -- label#1
          row
            []
            [ -- button#0 — the declaration: text and runs in one write
              buttonOn "seed" $ do
                let doc =
                      blockRun (13, 24) Heading2
                        . linkRun (7, 12) "https://kaya.dev"
                        . bold (0, 6)
                        $ documentOf docSource
                submitTx app $ do
                  setDocument app editor doc
                  writeSignal runs (VStr (spell (docRuns doc))),
              -- button#1 — the app's own edit, italic over the inserted word
              buttonOn "insert" $ do
                submitTx app
                  ( applyEdit app editor
                      (markEdit (2, 5) "italic" "true" (insertEdit 6 ", big"))
                  )
                doc <- document app editor
                submitTx app (writeSignal runs (VStr (spell (docRuns doc)))),
              -- button#2 — select the first word, for the toolbar act
              buttonOn "select word" (submitTx app (selectRange editor (0, 6))),
              -- button#3 — the toolbar: take bold off the selection
              buttonOn "unbold" (submitTx app (unformat editor "bold")),
              -- button#4 — a block act over the selection's paragraphs
              buttonOn "heading" (submitTx app (setBlock editor Heading1)),
              -- button#5 — focus, so the next keystroke is a USER edit
              buttonOn "focus" (submitTx app (focusWidget editor)),
              -- button#6 — clicked while a composition is live: the core
              -- holds the edit, the app's document takes it now
              buttonOn "prefix" $ do
                submitTx app (applyEdit app editor (insertEdit 0 "> "))
                doc <- document app editor
                submitTx app (writeSignal runs (VStr (spell (docRuns doc))))
            ]
        ]
    mount root
    return (editor, lastAct, runs)

  onEdit app editor $ \e -> do
    doc <- document app editor
    submitTx app $ do
      writeSignal
        lastAct
        ( VStr
            ( "edit " ++ show (editStart e) ++ ":" ++ show (editEnd e)
                ++ " <"
                ++ editInserted e
                ++ "> ["
                ++ spell (editRuns e)
                ++ "]"
            )
        )
      writeSignal runs (VStr (spell (docRuns doc)))
  onFormat app editor $ \act -> do
    doc <- document app editor
    submitTx app $ do
      writeSignal
        lastAct
        ( VStr
            ( "format " ++ show (formatStart act) ++ ":" ++ show (formatEnd act)
                ++ " "
                ++ formatName act
                ++ "="
                ++ maybe "off" id (formatValue act)
            )
        )
      writeSignal runs (VStr (spell (docRuns doc)))
