{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The toast scene, Haskell port — guests/rust/toast.rs,
-- tools/scenes/toast.steps, docs/toast-plan.md §5.

import Control.Monad.IO.Class (liftIO)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Item = Item {title :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

outcome :: ToastOutcome -> Text
outcome ToastAction = "action"
outcome ToastClosed = "closed"

titles :: RecordCollection Item -> Build Text
titles items = do
  all' <- map (title . snd) <$> recordItems items
  return (if null all' then "empty" else T.intercalate ", " all')

main :: IO ()
main = kayaMain $ \app -> do
  answersRef <- newIORef (0 :: Int)
  undosRef <- newIORef (0 :: Int)
  heldRef <- newIORef Nothing

  buildTx app $ do
    lastText <- signalText "no answer yet"
    countText <- signalText "answers 0"
    undoneText <- signalText "nothing undone"
    rowsText <- signalText "Milk, Eggs, Bread"
    items <- collectionOf @Item

    let answer text o = do
          answers <- atomicModifyIORef' answersRef (\n -> (n + 1, n + 1))
          submitTx app $ do
            writeSignal countText ("answers " <> tshow answers)
            writeSignal lastText (text <> ": " <> outcome o)
        ask text attrs = runAsk app $ do
          o <- askToast text attrs
          liftIO (answer text o)
        onDelete = do
          first <- buildTx app $ do
            entries <- recordItems items
            return (case entries of
              ((key, item') : _) -> Just (key, title item')
              [] -> Nothing)
          case first of
            Nothing -> return ()
            Just (key, name) -> do
              let text = "Deleted " <> name
              undoableTx app ("delete " <> name) $ do
                remove (recordHandle items) key
                list <- titles items
                writeSignal rowsText list
                _ <- showToast text [TAction "Undo", TUndo] (answer text)
                return ()
        onHold = do
          held <- buildTx app (showToast "Working" [TDuration ToastLong] (answer "Working"))
          writeIORef heldRef (Just held)
        onDismiss = do
          held <- readIORef heldRef
          writeIORef heldRef Nothing
          mapM_ (submitTx app . dismissToast) held
        walked label _ = do
          undos <- atomicModifyIORef' undosRef (\n -> (n + 1, n + 1))
          submitTx app $ do
            writeSignal undoneText ("undone " <> tshow undos <> ": " <> label)
            list <- titles items
            writeSignal rowsText list

    window
      primary
      [ WTitle "toast",
        WMenus
          [ menu
              "Edit"
              []
              [ item "Undo" [IRole roleUndo],
                item "Redo" [IRole roleRedo]
              ]
          ],
        WOnUndone walked
      ]

    root <-
      column
        [ labelBound lastText,
          labelBound countText,
          labelBound undoneText,
          labelBound rowsText,
          buttonOn "show" (ask "Saved" []),
          buttonOn "first" (ask "First" [TAction "Open"]),
          buttonOn "second" (ask "Second" [TAction "Open"]),
          buttonOn "delete" onDelete,
          buttonOn "hold" onHold,
          buttonOn "dismiss" onDismiss,
          each (recordHandle items) $ rowOf [label (field @"title" @Item)]
        ]
    mount root

    insertRecord items "Milk" (Item "Milk")
    insertRecord items "Eggs" (Item "Eggs")
    insertRecord items "Bread" (Item "Bread")
