{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The rich rows scene, Haskell port — guests/rust/richrows.rs,
-- tools/scenes/richrows.steps: a rich textarea per stamped ROW whose
-- document is a FIELD of the row (docs/rich-text-plan.md §19). The app
-- writes a copy's document by patching its row, and a copy's own act
-- folds into the row the app reads back.

import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Note = Note {title :: Text, body :: Document}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


-- The core's spelling of runs (`expect_runs`), so the row's field and the
-- core's mirror are compared as one string.
spell :: [Run] -> Text
spell = T.intercalate "|" . map one
  where
    one r
      | r.value == Flag True = span_ r <> r.name
      | otherwise = span_ r <> r.name <> "=" <> markSpelling r.value
    span_ r = tshow (fst r.range) <> ":" <> tshow (snd r.range) <> " "

noteAt :: [(Key, Note)] -> Text -> Note
noteAt items key = case [note | (k, note) <- items, keyText k == key] of
  (note : _) -> note
  [] -> error ("richrows: no row " ++ T.unpack key)

main :: IO ()
main = kayaMain $ \app -> do
  (notes, lastAct, bodyNode) <- buildTx app $ do
    notes <- collectionOf @Note
    lastAct <- signalText ""
    view <- signalText ""

    -- An undo or redo moved the row back: the app reads ITS OWN mirror of
    -- row b, which is the fold a restored Blob field lands in.
    let restored _label _delta = submitTx app $ do
          items <- recordItems notes
          let note = noteAt items "b"
          writeSignal
            view
            ((body note).text <> " | " <> spell (body note).runs)
    window
      primary
      [ WTitle "richrows",
        WMenus
          [ menu
              "Edit"
              []
              [ item "Undo" [IRole roleUndo],
                item "Redo" [IRole roleRedo]
              ]
          ],
        WOnUndone restored,
        WOnRedone restored
      ]

    lastLabel <- labelBound lastAct -- label#0
    viewLabel <- labelBound view -- label#1
    buttons <-
      row
        []
        [ -- button#0 — the app writes a copy by patching its row
          buttonOn "patch b" . undoableTx app "patch b" $
            patch
              notes
              "b"
              [set (field @"body" @Note) (italicRun (0, 7) (documentOf "Patched"))],
          -- button#1 — the row the copy's own act folded into
          buttonOn "read a" . submitTx app $ do
            items <- recordItems notes
            let note = noteAt items "a"
            writeSignal
              view
              ((body note).text <> " | " <> spell (body note).runs)
        ]
    (rows, bodyNode) <- forEach (recordHandle notes) $ do
      titleLabel <- label (field @"title" @Note)
      bodyNode <- withTplAttrs [TplA11yId "body"] (textareaRichBound (field @"body" @Note))
      _ <- columnOf [pure titleLabel, pure bodyNode]
      return bodyNode

    root <- column [] [pure lastLabel, pure viewLabel, pure buttons, pure rows]
    mount root

    insertRecord notes "a" (Note "a" (boldRun (0, 6) (documentOf "Héllo world")))
    insertRecord
      notes
      "b"
      (Note "b" (linkRun (7, 11) "https://kaya.dev" (documentOf "Second note")))
    return (notes, lastAct, bodyNode)

  -- The row's field already carries the copy's act when these fire: the
  -- app reads the row, never the widget.
  let acted [] = error "kaya: acted's key path is never empty"
      acted (key : _) = submitTx app $ do
        items <- recordItems notes
        let note = noteAt items (keyText key)
        writeSignal
          lastAct
          (keyText key <> ": " <> spell (body note).runs)
  onEditNode app bodyNode (\keys _ -> acted keys)
  onFormatNode app bodyNode (\keys _ -> acted keys)
