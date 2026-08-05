{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The undo scene from Haskell: two tiers, one Edit menu, and one ledger
   that orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).

   WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. 'undoableTx' names a
   transaction, and that name is the step: the core keeps the inverse of
   what the batch did to signals and collections, and hands it back
   through 'onUndone'. There is no undo stack in this file, no command
   objects, and no re-run of any handler — an undo is a programmatic
   write of the state that was there before, which is why it emits
   nothing and why the occurrence carries the whole delta.

   THE ENTRY POINT TAKES THE NAME because this binding's transaction is
   ambient: a Build is a pure state function with no handle to hang a
   name on, so the scope that opens the transaction is where the step is
   named (docs/undo-plan.md D2). The handle bindings spell the same
   thing on their transaction object.

   THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S, and this app writes
   nothing for it at all. Both tiers arrive through the same Edit>Undo
   item, and which one answers is kaya's routing question, not the
   app's (D6).

   THE SCENARIO THAT MOTIVATED THE MILESTONE is the add button, which is
   the entry scene's add: it appends a todo AND empties the field. Two
   transactions, deliberately — the undoable group is the insert and the
   status it wrote, and the clear that finishes the form is not part of
   the step. Under two unordered stacks one Cmd+Z takes back the CLEAR:
   "milk" returns to the field, the todo stays, and the user is looking
   at a state that never existed (docs/undo-plan.md §2). Here it takes
   back the ADD.

   It is also the design saying the same thing twice: 'clearWidget'
   inside a group is REFUSED at apply, because it destroys widget-owned
   text the core never held (D4). Undo restores state, and state is
   signals plus collections.

   Canonical semantics in guests/rust/undo.rs; the byte-frozen contract
   in tools/scenes/undo.steps. -}

import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

-- The record is the schema.
data Todo = Todo {title :: String} deriving (Generic)

instance KayaRecord Todo

-- | What the history label says a step was. A typing episode has no
-- authored name and kaya invents none ("Undo Typing" is an Apple
-- convention, not a scene string — docs/undo-plan.md D8), so the empty
-- label is the app's to spell.
what :: String -> String
what label = if null label then "typing" else label

main :: IO ()
main = kayaMain $ \app -> do
  -- The fold: widget-owned state arrives as occurrences; the app's copy
  -- is this IORef, not a widget read.
  draftRef <- newIORef ""
  keyRef <- newIORef (0 :: Int)

  (status, history, entryField, todos) <- buildTx app $ do
    -- THE GESTURE LAYER, one tier deeper: an app declares the two items
    -- and writes nothing else. They act on the focused widget, lower to
    -- the platform's own command where it has one, and work out their
    -- own enablement from what is focused and what the ledger holds.
    window
      0
      [ WTitle "undo",
        WMenus
          [ menu
              "Edit"
              []
              [ item "Undo" [IRole roleUndo],
                item "Redo" [IRole roleRedo]
              ]
          ]
      ]
    status <- signal (VStr "no todos")
    history <- signal (VStr "history empty")
    todos <- collectionOf (Proxy :: Proxy Todo)

    -- THE FIELD IS BUILT FIRST so the buttons can close over it: Build
    -- is a PURE state monad, so there is no IORef trick available
    -- inside it the way the impure bindings use one. Nothing moves in
    -- the scene — a widget's index is its creation order WITHIN ITS
    -- KIND — and `pure` slots it into the column at the position every
    -- other language puts it.
    entryField <- entryOn (writeIORef draftRef) [A11yId "draft"]

    let onAdd = do
          draft <- readIORef draftRef
          if null draft
            then submitTx app $ do
              total <- count (recordHandle todos)
              writeSignal status (VStr ("nothing to add, " ++ show total ++ " total"))
            else do
              key <- atomicModifyIORef' keyRef (\n -> (n + 1, n + 1))
              -- ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name is
              -- what the step is called; everything in this
              -- transaction is what it did.
              undoableTx app ("add " ++ draft) $ do
                insertRecord todos (VStr ("t" ++ show key)) (Todo draft)
                total <- count (recordHandle todos)
                writeSignal status (VStr ("added " ++ draft ++ ", " ++ show total ++ " total"))
                -- A PURE EFFECT rides along and is simply not restored:
                -- undo restores state, not where you were looking (A2).
                focusWidget entryField
              -- FINISHING THE FORM IS NOT PART OF THE STEP. Its own
              -- transaction, so undoing the add does not put the draft
              -- back beside a todo that is gone — and `clearWidget`
              -- inside a group would be refused anyway. The field
              -- empties on screen and reports text_changed("") through
              -- its normal edit path, so the fold above empties the
              -- draft.
              submitTx app (clearWidget entryField)
        -- A group at its smallest: one signal write, which is the
        -- undoable set's whole vocabulary on the reactive side.
        onStar = undoableTx app "star" (writeSignal status (VStr "starred"))
        -- THE SCENE'S WAY BACK TO THE FIELD. `star` does not move the
        -- cursor on its own — an app that reaches for focus after every
        -- action is deciding where the user is looking — so the scene
        -- says so itself, and the routing question ("what is focused?")
        -- stays visible in the script rather than hidden in a handler.
        onFocus = submitTx app (focusWidget entryField)

    root <-
      column
        [ labelBound status [A11yId "status"], -- label#0
          labelBound history [A11yId "history"], -- label#1
          pure entryField, -- entry#0
          buttonOn "add" onAdd, -- button#0
          buttonOn "star" onStar, -- button#1
          buttonOn "focus" onFocus, -- button#2
          each (recordHandle todos) (row [label (field @"title" @Todo)])
        ]
    -- THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
    -- holding focus when it does — and focus is the routing question's
    -- other half.
    focusWidget entryField
    mount root
    return (status, history, entryField, todos)

  -- Per window, and PERSISTENT: a history is walked as often as the
  -- user likes. The binding has already reconciled its collection model
  -- from this payload before the handler runs, which is why `count`
  -- below answers about the restored state.
  --
  -- THE DELTA IS THE ONLY NOTIFICATION for the text it put back:
  -- restoring an episode is a programmatic write, and a programmatic
  -- write never echoes, so an app that folds text_changed into its own
  -- state — which is every app, the field being uncontrolled — would go
  -- stale on exactly this step if the payload did not carry it (D5).
  let walked verb label delta = do
        case reverse (undoTexts delta) of
          ((_, text) : _) -> writeIORef draftRef text
          [] -> return ()
        submitTx app $ do
          total <- count (recordHandle todos)
          writeSignal history (VStr (verb ++ " " ++ what label ++ ", " ++ show total ++ " total"))
  onUndone app 0 (walked "undid")
  onRedone app 0 (walked "redid")
