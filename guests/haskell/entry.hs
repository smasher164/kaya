{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The entry scene, Haskell port — guests/rust/entry.rs,
-- tools/scenes/entry.steps.

import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Todo = Todo {title :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


main :: IO ()
main = kayaMain $ \app -> do
  (status, entryField, add, todos) <- buildTx app $ do
    status <- signal (T.pack "no todos")
    todos <- collectionOf @Todo

    -- Built ahead of the tree so the handlers below have handles to name.
    entryField <- entry
    add <- button "add"

    root <-
      column
        [ pure entryField, -- entry#0
          pure add, -- button#0
          labelBound status, -- label#0
          each (recordHandle todos) (label (field @"title" @Todo))
        ]
    mount root
    return (status, entryField, add, todos)

  draftRef <- newIORef ("" :: Text)
  onChange app entryField $ \text -> writeIORef draftRef text
  onClick app add $ do
    draft <- readIORef draftRef
    if T.null draft
      then submitTx app $ do
        total <- count (recordHandle todos)
        writeSignal status (T.pack ("nothing to add, " ++ show total ++ " total"))
      else submitTx app $ do
        _ <- insertFresh todos (Todo draft)
        total <- count (recordHandle todos)
        writeSignal status ("added " <> draft <> ", " <> T.pack (show total) <> " total")
        -- The clear comes back as text_changed "", so the fold empties draft.
        clearWidget entryField
        focusWidget entryField
