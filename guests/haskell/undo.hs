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

-- The undo scene, Haskell port — guests/rust/undo.rs, tools/scenes/undo.steps.

import Data.Int (Int64)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Todo = Todo {title :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


-- | kaya invents no label for a typing episode (docs/undo-plan.md D8).
what :: Text -> Text
what label = if T.null label then "typing" else label

-- | Every key the collection holds, in order.
keyList :: RecordCollection Todo -> Build String
keyList todos = do
  entries <- recordItems todos
  let ks = map (\(k, _) -> show (fromWire k :: Int64)) entries
  return (if null ks then "no keys" else "keys " ++ intercalate "," ks)

-- | The app's copy of what is typed in the ROWS: a note per todo key.
type Notes = Map.Map Int64 Text

-- | The row a stamped copy's occurrence names: for a top-level For the
-- path is one key, the todo's own.
rowKey (k : _) = fromWire k :: Int64
rowKey [] = error "kaya: a stamped copy's path is never empty"

-- | The notes, rendered: every note the app holds, by key.
noteList :: Notes -> String
noteList notes
  | Map.null notes = "no notes"
  | otherwise = "notes " ++ intercalate "," [show k ++ "=" ++ T.unpack v | (k, v) <- Map.toAscList notes]

-- | One note, folded in. An empty note is no note.
noteAt :: Int64 -> Text -> Notes -> Notes
noteAt key text
  | T.null text = Map.delete key
  | otherwise = Map.insert key text

-- | The empty path is the draft, a path names a row; the run is walked whole.
foldTexts :: IORef Text -> IORef Notes -> [UndoText] -> IO ()
foldTexts draftRef notesRef = mapM_ one
  where
    one t
      | null (utPath t) = writeIORef draftRef (utText t)
      | otherwise = modifyIORef' notesRef (noteAt (rowKey (utPath t)) (utText t))

main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ("" :: Text)
  notesRef <- newIORef (Map.empty :: Notes)

  (notes, noteNode) <- buildTx app $ do
    status <- signal (T.pack "no todos")
    history <- signal (T.pack "history empty")
    -- The shared script reads labels BY INDEX, so the declaration order of
    -- these two is contract.
    keys <- signal (T.pack "no keys")
    notes <- signal (T.pack "no notes")
    todos <- collectionOf @Todo

    -- Restoring never echoes, so the delta is the ONLY notification (D5).
    let walked verb label delta = do
          foldTexts draftRef notesRef (undoTexts delta)
          noted <- noteList <$> readIORef notesRef
          submitTx app $ do
            total <- count (recordHandle todos)
            writeSignal history (T.pack verb <> " " <> what label <> ", " <> T.pack (show total) <> " total")
            -- ONE transaction with the history label above: the script reads
            -- them in that order.
            list <- keyList todos
            writeSignal keys (T.pack list)
            writeSignal notes (T.pack noted)

    window
      primary
      [ WTitle "undo",
        WMenus
          [ menu
              "Edit"
              []
              [ item "Undo" [IRole roleUndo],
                item "Redo" [IRole roleRedo]
              ]
          ],
        WOnUndone (walked "undid"),
        WOnRedone (walked "redid")
      ]

    -- Built before the buttons that close over it: Build is a PURE state
    -- monad, so nothing can reach back for it later.
    entryField <- entryOn (writeIORef draftRef) [A11yId ("draft" :: Text)]

    let onAdd = do
          draft <- readIORef draftRef
          if T.null draft
            then submitTx app $ do
              total <- count (recordHandle todos)
              writeSignal status (T.pack ("nothing to add, " ++ show total ++ " total"))
            else do
              undoableTx app ("add " <> draft) $ do
                _ <- insertFresh todos (Todo draft)
                total <- count (recordHandle todos)
                writeSignal status ("added " <> draft <> ", " <> T.pack (show total) <> " total")
                list <- keyList todos
                writeSignal keys (T.pack list)
                -- A pure effect rides along and is not restored (A2).
                focusWidget entryField
              -- 'clearWidget' inside a group is refused at apply (D4).
              submitTx app (clearWidget entryField)
        -- Two transactions: a label that quotes the model is read BEFORE the
        -- group it names opens.
        onRemove = do
          first <- buildTx app $ do
            entries <- recordItems todos
            case entries of
              [] -> do
                total <- count (recordHandle todos)
                writeSignal status (T.pack ("nothing to remove, " ++ show total ++ " total"))
                return Nothing
              ((key, todo) : _) -> return (Just (key, title todo))
          case first of
            Nothing -> return ()
            Just (key, name) -> undoableTx app ("remove " <> name) $ do
              remove (recordHandle todos) key
              total <- count (recordHandle todos)
              writeSignal status ("removed " <> name <> ", " <> T.pack (show total) <> " total")
              list <- keyList todos
              writeSignal keys (T.pack list)
        onStar = undoableTx app "star" (writeSignal status (T.pack "starred"))
        onFocus = submitTx app (focusWidget entryField)

    -- 'forEach' rather than 'each': the node escapes the template, so the
    -- change handler is registered centrally against it (bottom of file).
    (todoRows, noteNode) <- forEach (recordHandle todos) $ do
      note <- entry
      _ <- rowOf [label (field @"title" @Todo), pure note]
      return note

    root <-
      column
        [ labelBound status [A11yId ("status" :: Text)], -- label#0
          labelBound history [A11yId ("history" :: Text)], -- label#1
          labelBound keys [A11yId ("keys" :: Text)], -- label#2
          labelBound notes [A11yId ("notes" :: Text)], -- label#3
          pure entryField, -- entry#0
          buttonOn "add" onAdd, -- button#0
          buttonOn "star" onStar, -- button#1
          buttonOn "focus" onFocus, -- button#2
          buttonOn "remove" onRemove, -- button#3
          pure todoRows
        ]
    -- The scene types real keystrokes, so something must hold focus.
    focusWidget entryField
    mount root
    return (notes, noteNode)

  -- Not an undoable group: an ordinary edit is the platform's step.
  onChange app noteNode $ \path text -> do
    modifyIORef' notesRef (noteAt (rowKey path) text)
    noted <- noteList <$> readIORef notesRef
    submitTx app (writeSignal notes (T.pack noted))
