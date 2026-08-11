{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The undo scene from Haskell: two tiers, one Edit menu, and one ledger
   that orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).

   WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. 'undoableTx' names a
   transaction, and that name is the step: the core keeps the inverse of
   what the batch did to signals and collections, and hands it back
   through the window's 'WOnUndone'. There is no undo stack in this file,
   no command objects, and no re-run of any handler — an undo is a
   programmatic write of the state that was there before, which is why it
   emits nothing and why the occurrence carries the whole delta.

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

   AND THE APP NAMES NO TODO. A todo is a title and nothing else — it has
   no identity of its own — so the key comes from 'insertFresh', which
   mints one per collection instance and hands it back
   (docs/fresh-key-plan.md). What that buys here is the whole point of
   the minter: this file used to carry a 'keyRef' counter beside the
   collection whose safety rested on never rewinding, and an undo that
   rewound it would have handed the same name to two todos.

   Canonical semantics in guests/rust/undo.rs; the byte-frozen contract
   in tools/scenes/undo.steps. -}

import Data.Int (Int64)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
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

-- | The app's collection mirror, rendered: every key it holds, in the
-- order it holds them.
--
-- THIS IS THE ONLY PART OF AN UNDO A COUNT CANNOT SEE. A restored entry
-- that came back under a fresh name, or at the end instead of where it
-- was, leaves every total in this file correct — the entries and orders
-- runs of the delta are what say otherwise, and this is where the scene
-- reads them (D5).
keyList :: RecordCollection Todo -> Build String
keyList todos = do
  entries <- recordItems todos
  -- The minter's keys are I64, and the binding's own field conversion
  -- is what turns one back into a number.
  let ks = map (show . (fromFieldValue :: Value -> Int64) . fst) entries
  return (if null ks then "no keys" else "keys " ++ intercalate "," ks)

-- | The app's copy of what is typed in the ROWS: a note per todo key.
type Notes = Map.Map Int64 String

-- | The row a stamped copy's occurrence names: the copy's key path,
-- which for a top-level For is one key — the todo's own, minted by
-- 'insertFresh' and read back through the binding's field conversion,
-- exactly as 'keyList' reads the collection's keys.
rowKey :: [Value] -> Int64
rowKey (k : _) = fromFieldValue k
rowKey [] = error "kaya: a stamped copy's path is never empty"

-- | The notes, rendered: every note the app holds, by key.
--
-- THE ROWS' FIELDS ARE UNCONTROLLED LIKE THE DRAFT, so this map is the
-- app's own and nothing reads it back off a widget. It is also where
-- this scene proves the payload's new shape: an undone note arrives
-- naming (template node, key path), and an app with two rows can only
-- put it back in the right one because the path says which.
noteList :: Notes -> String
noteList notes
  | Map.null notes = "no notes"
  | otherwise = "notes " ++ intercalate "," [show k ++ "=" ++ v | (k, v) <- Map.toAscList notes]

-- | One note, folded in. AN EMPTY NOTE IS NO NOTE, which is what makes
-- the undo in the scene falsifiable: the restore of a row's field to ""
-- has to REMOVE the key, so an app that ignored the payload reads its
-- stale note back out and the script says so.
noteAt :: Int64 -> String -> Notes -> Notes
noteAt key text
  | null text = Map.delete key
  | otherwise = Map.insert key text

-- | One texts run, folded into the app's two mirrors of widget-owned
-- text. The empty path is the draft; a path names a row.
--
-- THE RUN IS WALKED WHOLE, not reduced to its last member, because an
-- entry NAMES the field it restores and one step can restore both
-- kinds at once.
foldTexts :: IORef String -> IORef Notes -> [UndoText] -> IO ()
foldTexts draftRef notesRef = mapM_ one
  where
    one t
      | null (utPath t) = writeIORef draftRef (utText t)
      | otherwise = modifyIORef' notesRef (noteAt (rowKey (utPath t)) (utText t))

main :: IO ()
main = kayaMain $ \app -> do
  -- The fold: widget-owned state arrives as occurrences; the app's copy
  -- is these two IORefs, not a widget read. Two of them, because there
  -- are two kinds of text field on screen — the draft, and one per row
  -- — and the payload's path is what tells them apart.
  draftRef <- newIORef ""
  notesRef <- newIORef (Map.empty :: Notes)

  (notes, noteNode) <- buildTx app $ do
    status <- signal (VStr "no todos")
    history <- signal (VStr "history empty")
    -- THE APP'S MIRROR, RENDERED. Declared third and read as label#2 in
    -- every language, which is contract and not convention: with no
    -- third static label the index resolves to the first STAMPED row
    -- and the assertion reads a todo title instead of failing loud.
    keys <- signal (VStr "no keys")
    -- label#3: the same mirror one level down, for the text the ROWS
    -- own. Declared fourth and read as label#3 in every language.
    notes <- signal (VStr "no notes")
    todos <- collectionOf (Proxy :: Proxy Todo)

    -- Per window, and PERSISTENT: a history is walked as often as the
    -- user likes. The binding has already reconciled its collection
    -- model from this payload before the handler runs, which is why
    -- `count` and `recordItems` below answer about the restored state.
    --
    -- THE DELTA IS THE ONLY NOTIFICATION for the text it put back:
    -- restoring an episode is a programmatic write, and a programmatic
    -- write never echoes, so an app that folds text_changed into its own
    -- state — which is every app, the field being uncontrolled — would go
    -- stale on exactly this step if the payload did not carry it (D5).
    -- The scene reads that stale copy out loud one step later, at the
    -- add that refuses an empty draft.
    let walked verb label delta = do
          foldTexts draftRef notesRef (undoTexts delta)
          noted <- noteList <$> readIORef notesRef
          submitTx app $ do
            total <- count (recordHandle todos)
            writeSignal history (VStr (verb ++ " " ++ what label ++ ", " ++ show total ++ " total"))
            -- ONE TRANSACTION WITH THE LABEL ABOVE, deliberately: the
            -- script reads that label first, so by the time it reads
            -- this one the app's own answer is what is on screen — not
            -- the value the core restored on its way past. The notes
            -- ride the same transaction for the same reason.
            list <- keyList todos
            writeSignal keys (VStr list)
            writeSignal notes (VStr noted)

    -- THE GESTURE LAYER, one tier deeper: an app declares the two items
    -- and writes nothing else. They act on the focused widget, lower to
    -- the platform's own command where it has one, and work out their
    -- own enablement from what is focused and what the ledger holds.
    --
    -- The two history handlers ride this same construct, because the
    -- ledger is per window and a window's attributes are exactly what
    -- its construct takes — nothing about a window is a loose function
    -- registered after the fact.
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
          ],
        WOnUndone (walked "undid"),
        WOnRedone (walked "redid")
      ]

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
              -- NOT A STEP, so it names no group and the forward
              -- history survives it. It is also the one place this app
              -- READS ITS OWN DRAFT out loud, which is how the script
              -- proves the restored text of an undone typing episode
              -- reached it at all.
              total <- count (recordHandle todos)
              writeSignal status (VStr ("nothing to add, " ++ show total ++ " total"))
            else do
              -- ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name is
              -- what the step is called; everything in this
              -- transaction is what it did.
              undoableTx app ("add " ++ draft) $ do
                -- NO KEY, AND NO COUNTER TO GET WRONG: the binding
                -- mints the name and hands it back. This app has no use
                -- for it — a todo is looked up by nothing — and an app
                -- that does (selecting the new row, say) takes it from
                -- here rather than inventing a second name for the same
                -- datum.
                _ <- insertFresh todos (Todo draft)
                total <- count (recordHandle todos)
                writeSignal status (VStr ("added " ++ draft ++ ", " ++ show total ++ " total"))
                list <- keyList todos
                writeSignal keys (VStr list)
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
        -- THE STEP WHOSE INVERSE IS AN IDENTITY, not a content. The core
        -- captured the entry and the instance's order before the
        -- removal, so undoing this puts the entry back under the key it
        -- already had, where it already was — neither of which this app
        -- has to remember.
        --
        -- IN TWO TRANSACTIONS BECAUSE THE NAME IS THE SCOPE'S. This
        -- binding's group is named where it opens, so a label that
        -- quotes the model ("remove milk") is read in the transaction
        -- BEFORE the one it names — the ambient tier's shape, where the
        -- handle bindings read and name on the transaction they already
        -- hold. The read is the model's own answer, never a widget's,
        -- so the entry that comes back has to come back before the one
        -- that stayed.
        onRemove = do
          first <- buildTx app $ do
            entries <- recordItems todos
            case entries of
              [] -> do
                total <- count (recordHandle todos)
                writeSignal status (VStr ("nothing to remove, " ++ show total ++ " total"))
                return Nothing
              ((key, todo) : _) -> return (Just (key, title todo))
          case first of
            Nothing -> return ()
            Just (key, name) -> undoableTx app ("remove " ++ name) $ do
              remove (recordHandle todos) key
              total <- count (recordHandle todos)
              writeSignal status (VStr ("removed " ++ name ++ ", " ++ show total ++ " total"))
              list <- keyList todos
              writeSignal keys (VStr list)
        -- A group at its smallest: one signal write, which is the
        -- undoable set's whole vocabulary on the reactive side.
        onStar = undoableTx app "star" (writeSignal status (VStr "starred"))
        -- THE SCENE'S WAY BACK TO THE FIELD. `star` does not move the
        -- cursor on its own — an app that reaches for focus after every
        -- action is deciding where the user is looking — so the scene
        -- says so itself, and the routing question ("what is focused?")
        -- stays visible in the script rather than hidden in a handler.
        onFocus = submitTx app (focusWidget entryField)

    -- THE ROW'S OWN FIELD, and the reason this scene grew: a copy's
    -- text edits are the same occurrence a live field's are, one
    -- identity deeper, and the ledger banks them the same way now that
    -- the payload can name them. 'entry' with nothing to bind, because
    -- the field is UNCONTROLLED: the copy owns its text from the first
    -- keystroke, and this scene's whole point is that the app folds
    -- those edits into its own state. ('entryBound' is the sibling that
    -- seeds each copy from its row.)
    --
    -- 'forEach' rather than 'each' because the change handler is
    -- registered centrally against the NODE, exactly as a stamped
    -- button's click is: Build is a pure state monad with no App to
    -- hand a handler to, so the node escapes the template and 'pure'
    -- slots it into the row where it stands.
    (todoRows, noteNode) <- forEach (recordHandle todos) $ do
      note <- entry
      _ <- rowOf [label (field @"title" @Todo), pure note]
      return note

    root <-
      column
        [ labelBound status [A11yId "status"], -- label#0
          labelBound history [A11yId "history"], -- label#1
          labelBound keys [A11yId "keys"], -- label#2
          labelBound notes [A11yId "notes"], -- label#3
          pure entryField, -- entry#0
          buttonOn "add" onAdd, -- button#0
          buttonOn "star" onStar, -- button#1
          buttonOn "focus" onFocus, -- button#2
          buttonOn "remove" onRemove, -- button#3
          pure todoRows
        ]
    -- THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
    -- holding focus when it does — and focus is the routing question's
    -- other half.
    focusWidget entryField
    mount root
    return (notes, noteNode)

  -- The row's edit, folded exactly as the payload's restore of the same
  -- field will be — one rule, two arrival paths, so the script's
  -- assertion cannot pass through a second spelling of "what a note is".
  -- Its own transaction, and not an undoable one: an ordinary edit is
  -- the platform's step, not the ledger's.
  onChangeNode app noteNode $ \path text -> do
    modifyIORef' notesRef (noteAt (rowKey path) text)
    noted <- noteList <$> readIORef notesRef
    submitTx app (writeSignal notes (VStr noted))
