{-# LANGUAGE OverloadedStrings #-}

-- The rich text scene, Haskell port — guests/rust/richtext.rs,
-- tools/scenes/richtext.steps. THE OFFSETS ARE UTF-8 BYTES; the é in the
-- first word is what makes a UTF-16 reader fail (docs/ranges-units.md).

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

docSource :: Text
docSource = "Héllo world\nSecond line"

-- The core's spelling of runs (`expect_runs`), so the binding's document
-- and the core's mirror are compared as one string.
spell :: [Run] -> Text
spell = T.intercalate "|" . map one
  where
    one r
      | r.value == Flag True = span_ r <> r.name
      | otherwise = span_ r <> r.name <> "=" <> markSpelling r.value
    span_ r = tshow (fst r.range) <> ":" <> tshow (snd r.range) <> " "

main :: IO ()
main = kayaMain $ \app -> do
  (editor, lastAct, runs) <- buildTx app $ do
    window primary [WTitle "richtext"]
    lastAct <- signalText ""
    runs <- signalText ""

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
                        . boldRun (0, 6)
                        $ documentOf docSource
                submitTx app $ do
                  setDocument app editor doc
                  writeSignal runs (spell doc.runs),
              -- button#1 — the app's own edit, italic over the inserted word
              buttonOn "insert" $ do
                submitTx app
                  ( applyEdit app editor
                      (markEdit (2, 5) "italic" (Flag True) (insertEdit 6 ", big"))
                  )
                doc <- document app editor
                submitTx app (writeSignal runs (spell doc.runs)),
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
                submitTx app (writeSignal runs (spell doc.runs))
            ]
        ]
    mount root
    return (editor, lastAct, runs)

  onEdit app editor $ \e -> do
    doc <- document app editor
    submitTx app $ do
      writeSignal
        lastAct
        ( "edit " <> tshow (fst e.range) <> ":" <> tshow (snd e.range)
            <> " <"
            <> e.inserted
            <> "> "
            <> maybe "?" editSourceName e.source
            <> " ["
            <> spell e.runs
            <> "]"
        )
      writeSignal runs (spell doc.runs)
  onFormat app editor $ \act -> do
    doc <- document app editor
    submitTx app $ do
      writeSignal
        lastAct
        ( "format " <> tshow (fst act.range) <> ":" <> tshow (snd act.range)
            <> " "
            <> act.name
            <> "="
            <> maybe "off" markSpelling act.value
        )
      writeSignal runs (spell doc.runs)
