{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The entry scene, Haskell port — guests/rust/entry.rs,
-- tools/scenes/entry.steps.

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data Todo = Todo {title :: String} deriving (Generic)

instance KayaRecord Todo

main :: IO ()
main = kayaMain $ \app -> do
  (status, entryField, add, todos) <- buildTx app $ do
    status <- signal (VStr "no todos")
    todos <- collectionOf (Proxy :: Proxy Todo)

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

  draftRef <- newIORef ""
  onChange app entryField $ \text -> writeIORef draftRef text
  onClick app add $ do
    draft <- readIORef draftRef
    if null draft
      then submitTx app $ do
        total <- count (recordHandle todos)
        writeSignal status (VStr ("nothing to add, " ++ show total ++ " total"))
      else submitTx app $ do
        _ <- insertFresh todos (Todo draft)
        total <- count (recordHandle todos)
        writeSignal status (VStr ("added " ++ draft ++ ", " ++ show total ++ " total"))
        -- The clear comes back as text_changed "", so the fold empties draft.
        clearWidget entryField
        focusWidget entryField
