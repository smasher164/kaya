{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The rich rows scene, Haskell port — guests/rust/richrows.rs,
-- tools/scenes/richrows.steps: a rich textarea per stamped ROW whose
-- document is a FIELD of the row (docs/rich-text-plan.md §19). The app
-- writes a copy's document by patching its row, and a copy's own act
-- folds into the row the app reads back.

import Data.List (intercalate)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data Note = Note {title :: String, body :: Document} deriving (Generic)

instance KayaRecord Note

-- The core's spelling of runs (`expect_runs`), so the row's field and the
-- core's mirror are compared as one string.
spell :: [Run] -> String
spell = intercalate "|" . map one
  where
    one r
      | runValue r == "true" = span_ r ++ runName r
      | otherwise = span_ r ++ runName r ++ "=" ++ runValue r
    span_ r = show (runStart r) ++ ":" ++ show (runEnd r) ++ " "

keyText :: Value -> String
keyText v = case v of
  VStr s -> s
  VI64 n -> show n
  _ -> "?"

noteAt :: [(Value, Note)] -> Value -> Note
noteAt items key = case lookup key items of
  Just note -> note
  Nothing -> error ("richrows: no row " ++ keyText key)

main :: IO ()
main = kayaMain $ \app -> do
  (notes, lastAct, bodyNode) <- buildTx app $ do
    notes <- collectionOf (Proxy :: Proxy Note)
    lastAct <- signal (VStr "")
    view <- signal (VStr "")

    -- An undo or redo moved the row back: the app reads ITS OWN mirror of
    -- row b, which is the fold a restored Blob field lands in.
    let restored _label _delta = submitTx app $ do
          items <- recordItems notes
          let note = noteAt items (VStr "b")
          writeSignal
            view
            (VStr (docText (body note) ++ " | " ++ spell (docRuns (body note))))
    window
      0
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
              (VStr "b")
              [set (field @"body" @Note) (italicRun (0, 7) (documentOf "Patched"))],
          -- button#1 — the row the copy's own act folded into
          buttonOn "read a" . submitTx app $ do
            items <- recordItems notes
            let note = noteAt items (VStr "a")
            writeSignal
              view
              (VStr (docText (body note) ++ " | " ++ spell (docRuns (body note))))
        ]
    (rows, bodyNode) <- forEach (recordHandle notes) $ do
      titleLabel <- label (field @"title" @Note)
      bodyNode <- withTplAttrs [TplA11yId "body"] (textareaRichBound (field @"body" @Note))
      _ <- columnOf [pure titleLabel, pure bodyNode]
      return bodyNode

    root <- column [] [pure lastLabel, pure viewLabel, pure buttons, pure rows]
    mount root

    insertRecord notes (VStr "a") (Note "a" (boldRun (0, 6) (documentOf "Héllo world")))
    insertRecord
      notes
      (VStr "b")
      (Note "b" (linkRun (7, 11) "https://kaya.dev" (documentOf "Second note")))
    return (notes, lastAct, bodyNode)

  -- The row's field already carries the copy's act when these fire: the
  -- app reads the row, never the widget.
  let acted keys = submitTx app $ do
        items <- recordItems notes
        let key = head keys
            note = noteAt items key
        writeSignal
          lastAct
          (VStr (keyText key ++ ": " ++ spell (docRuns (body note))))
  onEditNode app bodyNode (\keys _ -> acted keys)
  onFormatNode app bodyNode (\keys _ -> acted keys)
