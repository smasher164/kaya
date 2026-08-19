{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The entry scene from Haskell: the uncontrolled contract end to end.
   The field owns its text and reports each edit through onChange; the
   app folds those into an IORef.

   WHAT THIS SCENE DOCUMENTS IS THE OTHER EVENT SURFACE — the handlers
   are registered on the APP after the build, not at the constructor.
   Every leaf constructor for a widget that produces events takes its
   handler as a REQUIRED argument, so this binding has no empty slot to
   pass; the two widgets registered below use the generic constructor.

   Build like milestone2.hs, then run with KAYA_SELFTEST=entry. -}

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

    -- Built ahead of the tree so the handlers below have handles to
    -- name; `pure` slots them into the column at the position they
    -- occupy in every other language.
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
        -- Finish the form, atomically with the insert: the field answers
        -- with text_changed "" and the fold above empties the draft.
        clearWidget entryField
        focusWidget entryField
