{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}
-- A key path's wire tag (KayaWire.Value) has no spelling a guest may
-- write (tools/check-sugar-surface.py's wire-tag clause) — the
-- fromWire-decoding helper below is left unsigned so its argument
-- type is inferred, never named.

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
      | runValue r == "true" = span_ r <> runName r
      | otherwise = span_ r <> runName r <> "=" <> runValue r
    span_ r = T.pack (show (runStart r) ++ ":" ++ show (runEnd r) ++ " ")

-- The key path's own wire tag decoded through 'fromWire', never named:
-- the argument's type (the wire's Value) has no spelling a guest may
-- write (tools/check-sugar-surface.py's wire-tag clause) — inferred here
-- from its call sites instead.
keyText v = fromWire v :: Text

noteAt items key = case lookup key items of
  Just note -> note
  Nothing -> error ("richrows: no row " ++ T.unpack (keyText key))

main :: IO ()
main = kayaMain $ \app -> do
  (notes, lastAct, bodyNode) <- buildTx app $ do
    notes <- collectionOf @Note
    lastAct <- signal ("" :: Text)
    view <- signal ("" :: Text)

    -- An undo or redo moved the row back: the app reads ITS OWN mirror of
    -- row b, which is the fold a restored Blob field lands in.
    let restored _label _delta = submitTx app $ do
          items <- recordItems notes
          let note = noteAt items (toWire ("b" :: Text))
          writeSignal
            view
            (docText (body note) <> " | " <> spell (docRuns (body note)))
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
              ("b" :: Text)
              [set (field @"body" @Note) (italicRun (0, 7) (documentOf "Patched"))],
          -- button#1 — the row the copy's own act folded into
          buttonOn "read a" . submitTx app $ do
            items <- recordItems notes
            let note = noteAt items (toWire ("a" :: Text))
            writeSignal
              view
              (docText (body note) <> " | " <> spell (docRuns (body note)))
        ]
    (rows, bodyNode) <- forEach (recordHandle notes) $ do
      titleLabel <- label (field @"title" @Note)
      bodyNode <- withTplAttrs [TplA11yId ("body" :: Text)] (textareaRichBound (field @"body" @Note))
      _ <- columnOf [pure titleLabel, pure bodyNode]
      return bodyNode

    root <- column [] [pure lastLabel, pure viewLabel, pure buttons, pure rows]
    mount root

    insertRecord notes ("a" :: Text) (Note "a" (boldRun (0, 6) (documentOf "Héllo world")))
    insertRecord
      notes
      ("b" :: Text)
      (Note "b" (linkRun (7, 11) "https://kaya.dev" (documentOf "Second note")))
    return (notes, lastAct, bodyNode)

  -- The row's field already carries the copy's act when these fire: the
  -- app reads the row, never the widget.
  let acted [] = error "kaya: acted's key path is never empty"
      acted (key : _) = submitTx app $ do
        items <- recordItems notes
        let note = noteAt items key
        writeSignal
          lastAct
          (keyText key <> ": " <> spell (docRuns (body note)))
  onEditNode app bodyNode (\keys _ -> acted keys)
  onFormatNode app bodyNode (\keys _ -> acted keys)
