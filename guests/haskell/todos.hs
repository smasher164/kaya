{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The todos scene from Haskell, on the construction sugar: the type is
   the schema (deriving Generic + a KayaRecord instance), constructors
   carry their props and handlers, containers take their children, and
   the do-block reads as the tree. The sugar lowers eagerly to the same
   records as the explicit floor — the C guests keep that style on
   purpose.

   THE DERIVED LABEL COMES BACK FROM AN UNDO AND NOTHING IN THIS FILE
   PUTS IT THERE. The add is a named step ('undoableTx'), and the
   derive's write is in that same batch: 'insertFresh' recomputes and
   appends an ordinary signal write to the transaction that caused it,
   so the core banks the label in both directions of the step and hands
   it back together with the collection. That is why nothing here
   registers 'WOnUndone' — there is no fixing up left for a handler to
   do, and a binding that recomputed derived signals while absorbing the
   payload would be writing a value the ledger never banked ('absorbUndo'
   in bindings/haskell/KayaApp.hs states the same stance from the other
   end).

   Build like milestone2.hs, then run with KAYA_SELFTEST=todos. -}

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

-- The record is the schema.
data Todo = Todo {title :: String, done :: Bool} deriving (Generic)

instance KayaRecord Todo

main :: IO ()
main = kayaMain $ \app -> do
  -- The fold: widget-owned state arrives as occurrences; the app's
  -- copy is this IORef, not a widget read.
  draftRef <- newIORef ""

  buildTx app $ do
    -- THE GESTURE LAYER, and these two items are the whole of it: an
    -- app declares them and writes nothing else. They act on whatever
    -- is focused, lower to the platform's own command where it has one,
    -- and work out their own enablement from what the ledger holds
    -- (docs/undo-plan.md D1-D6). No undo handler rides along on this
    -- construct, because the state the two items walk is the core's.
    window
      0
      [ WTitle "todos",
        WMenus
          [ menu
              "Edit"
              []
              [ item "Undo" [IRole roleUndo],
                item "Redo" [IRole roleRedo]
              ]
          ]
      ]

    todos <- collectionOf (Proxy :: Proxy Todo)
    -- The items-left label is a derived signal: the binding recomputes
    -- it from the collection after every mutation and writes it INTO
    -- THAT SAME TRANSACTION, so no handler mentions it — and the undo
    -- below gets it back for free.
    itemsLeft <-
      derive todos $ \entries ->
        let n = length (filter (not . done . snd) entries)
         in VStr (if n == 1 then "1 item left" else show n ++ " items left")

    entryField <- entryOn (writeIORef draftRef)

    let onAdd = do
          draft <- readIORef draftRef
          -- The empty-draft guard every real form has: nothing to
          -- insert, nothing to command.
          if null draft
            then return ()
            else do
              -- ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. What brings
              -- the items-left label back with the todo is that the
              -- derive's write is in this batch: the insert recomputes
              -- and appends an ordinary signal write, and a named
              -- transaction banks every signal it dirtied in both of
              -- its directions. So this step's inverse carries
              -- "0 items left" and its forward carries "1 item left",
              -- and the label is restored by the same mechanism as the
              -- collection it counts.
              undoableTx app ("add " ++ draft) $ do
                -- A todo is a title and a checkbox — it has no identity
                -- of its own — so the binding authors the key and hands
                -- it back (docs/fresh-key-plan.md). This file used to
                -- keep an IORef counter beside the collection for the
                -- job; that is what the minter replaces.
                _ <- insertFresh todos (Todo draft False)
                return ()
              -- FINISHING THE FORM IS NOT PART OF THE STEP. Its own
              -- transaction, so undoing the add does not put the draft
              -- back beside a todo that is gone — and 'clearWidget'
              -- inside a group is refused at apply anyway (D4), because
              -- it destroys widget-owned text the core never held. The
              -- field empties on screen and reports text_changed("")
              -- through its normal edit path (the fold empties the
              -- draft), and the cursor lands back in it.
              submitTx app $ do
                clearWidget entryField
                focusWidget entryField
        onToggle keys checked =
          submitTx app $
            -- One field's delta: the title never travels; the derived
            -- signal updates itself.
            patch todos (head keys) [set (field @"done" @Todo) checked]

    root <-
      column
        [ pure entryField,
          buttonOn "Add" onAdd,
          labelBound itemsLeft,
          each (recordHandle todos) $
            rowOf
              [ checkbox (field @"done" @Todo) onToggle,
                label (field @"title" @Todo)
              ]
        ]
    mount root
