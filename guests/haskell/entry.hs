{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The entry scene from Haskell: the uncontrolled contract end to end.
   The field owns its text and reports each edit through onChange; the
   app folds those into an IORef (draft) — its own model, per doctrine.
   The add button inserts the draft and answers with the count read
   from the collection model, then clears and refocuses the field —
   one-shot commands riding the insert's transaction; the clear's own
   text_changed "" re-enters through the fold and empties the draft,
   so a second add finds nothing to add.

   WHAT THIS SCENE DOCUMENTS IS THE OTHER EVENT SURFACE. Every other
   Haskell guest co-locates its handler at the constructor ('entryOn',
   'buttonOn'); here the two handlers are registered on the APP after
   the build, against the widgets the build handed back — the same two
   registries the co-located ones land in, reached by their own names.
   Construction is the ordinary sugar (DESIGN.md, entry's scope
   ratified 2026-08-05): the carve-out is the event mechanism, not the
   tree.

   THE FIELD AND THE BUTTON ARE THE ONE PLACE THE TWO MEET, and this
   binding's sugar has no spelling for it: every leaf constructor for a
   widget that produces events takes its handler as a required argument
   and registers it during the build, so there is no empty slot to pass
   the way Go's `tx.Entry(nil)` passes one. The two widgets whose events
   are registered below are therefore made with the generic constructor
   and named again there.

   Build like milestone2.hs, then run with KAYA_SELFTEST=entry. -}

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

-- The record is the schema. A todo here is a line of text and nothing
-- else, which is exactly why it has no name of its own to be given.
data Todo = Todo {title :: String} deriving (Generic)

instance KayaRecord Todo

main :: IO ()
main = kayaMain $ \app -> do
  (status, entryField, add, todos) <- buildTx app $ do
    status <- signal (VStr "no todos")
    todos <- collectionOf (Proxy :: Proxy Todo)

    -- The two widgets this app registers events for, built ahead of
    -- the tree so the handlers below have handles to name (see the
    -- header). `pure` slots them into the column at the position they
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

  -- The fold: widget-owned state arrives as occurrences; the app's
  -- copy is this IORef, not a widget read.
  draftRef <- newIORef ""
  onChange app entryField $ \text -> writeIORef draftRef text
  onClick app add $ do
    draft <- readIORef draftRef
    -- The empty-draft guard every real form has — and the scene's
    -- proof that clear emptied the draft through the occurrence fold,
    -- not a side assignment.
    if null draft
      then submitTx app $ do
        total <- count (recordHandle todos)
        writeSignal status (VStr ("nothing to add, " ++ show total ++ " total"))
      else submitTx app $ do
        -- NO KEY, AND NO COUNTER TO GET WRONG: a line of text has no
        -- identity of its own, so the binding mints the name and hands
        -- it back (docs/fresh-key-plan.md). This file used to keep an
        -- IORef counter beside the collection for the job, and its
        -- safety rested on never rewinding it. An app that needs the
        -- name — to select the new row, say — takes it from here
        -- rather than inventing a second name for the same datum.
        _ <- insertFresh todos (Todo draft)
        total <- count (recordHandle todos)
        writeSignal status (VStr ("added " ++ draft ++ ", " ++ show total ++ " total"))
        -- Finish the form: drop the field's content and put the
        -- cursor back, atomically with the insert. The field answers
        -- with text_changed "" through its normal edit path, and the
        -- fold above empties the draft.
        clearWidget entryField
        focusWidget entryField
