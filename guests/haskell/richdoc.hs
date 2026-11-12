{-# LANGUAGE OverloadedStrings #-}

-- The rich document scene, Haskell port — guests/rust/richdoc.rs,
-- tools/scenes/richdoc.steps (docs/rich-document-plan.md §9 step 2): a
-- heading, a body paragraph with a preset colour, a bullet list with a
-- nested item, a numbered list and a checklist, then the paragraph acts from
-- buttons, the platform's colour picker and a `.kdoc` round trip, then a file
-- carrying keys this kaya does not know (RD17). label#1 is the binding's own
-- Document, folded from the same deltas, so it must spell what the core holds.

import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import KayaApp

-- BYTE-IDENTICAL to guests/rust/richdoc.rs's DOC.
docSource :: Text
docSource = "Groceries\nFresh from the market.\nApples\nGreen ones\nBread\nWash\nSlice\nMilk\nEggs"

-- BYTE-IDENTICAL to guests/rust/richdoc.rs's UNKNOWN.
unknown :: Text
unknown = "{\"kaya\": \"document\", \"version\": 1, \"com.example.theme\": {\"page\": \"sepia\"}, \"paragraphs\": [{\"embed\": \"e1\", \"spans\": [[\"Loose\"]]}, {\"com.example.pinned\": true, \"spans\": [[\"Pinned\"]]}]}"

quoted :: Text -> Text
quoted = T.replace "\"" "'"

spell :: [Run] -> Text
spell = T.intercalate "|" . map one
  where
    one r
      | r.value == Flag True = span_ r <> r.name
      | otherwise = span_ r <> r.name <> "=" <> markSpelling r.value
    span_ r = tshow (fst r.range) <> ":" <> tshow (snd r.range) <> " "

seeded :: Document
seeded =
  listRun (68, 77) ListCheck
    . checkedRun (68, 72)
    . listRun (57, 67) ListNumbered
    . indentRun (40, 50) 1
    . listRun (33, 56) ListBullet
    . colorRun (25, 31) "#016FEF"
    . blockRun (0, 9) Heading1
    $ documentOf docSource

main :: IO ()
main = kayaMain $ \app -> do
  (editor, lastAct, runs) <- buildTx app $ do
    window
      primary
      [ WTitle "richdoc",
        WSize 560 620,
        WMenus
          [ menu
              "Edit"
              []
              [ item "Cut" [IRole roleCut],
                item "Copy" [IRole roleCopy],
                item "Paste" [IRole rolePaste]
              ]
          ]
      ]
    lastAct <- signalText ""
    runs <- signalText (spell seeded.runs)
    kdoc <- signalText ""

    -- Realized here because the handlers below need their handles.
    editor <- textarea [Rich True, Grow 1, A11yId "doc", A11yLabel "Document"]
    root <-
      column
        []
        [ pure editor, -- textarea#0
          labelBound lastAct, -- label#0
          labelBound runs, -- label#1
          labelBound kdoc, -- label#2
          row
            []
            [ buttonOn "numbered" (submitTx app (setList editor ListNumbered)), -- button#0
              buttonOn "indent" (submitTx app (indent editor)), -- button#1
              buttonOn "red" (submitTx app (color editor "#DD1F24")), -- button#2
              buttonOn "colour" (submitTx app (pickTextColor editor)), -- button#3
              buttonOn "kdoc" $ do -- button#4
                now <- document app editor
                let bytes = toKdoc now
                back <- either (fail . T.unpack) pure (fromKdoc bytes)
                submitTx app $ do
                  setDocument app editor back.document
                  writeSignal
                    kdoc
                    ( "kdoc " <> tshow (BS.length bytes) <> " bytes, read_only "
                        <> fromMaybe "none" back.readOnly
                        <> ", same "
                        <> (if back.document == now then "true" else "false")
                        <> ", extra "
                        <> (if T.null back.document.extra then "none" else quoted back.document.extra)
                    )
                  writeSignal runs (spell back.document.runs),
              buttonOn "unknown" $ do -- button#5
                file <- either (fail . T.unpack) pure (fromKdoc (TE.encodeUtf8 unknown))
                submitTx app $ do
                  setDocument app editor file.document
                  writeSignal
                    kdoc
                    ( "opened read_only " <> fromMaybe "none" file.readOnly
                        <> ", extra "
                        <> quoted file.document.extra
                    )
                  writeSignal runs (spell file.document.runs)
            ]
        ]
    mount root
    setDocument app editor seeded
    return (editor, lastAct, runs)

  onEdit app editor $ \e -> do
    doc <- document app editor
    submitTx app $ do
      writeSignal
        lastAct
        ( "edit " <> tshow (fst e.range) <> ":" <> tshow (snd e.range)
            <> " <"
            <> T.replace "\n" "\\n" e.inserted
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
