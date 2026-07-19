{- The entry scene from Haskell: the uncontrolled contract end to end.
   The field owns its text and reports each edit through onChange; the
   app folds those into an IORef (draft) — its own model, per doctrine.
   The add button inserts the draft and answers with the count read
   from the collection model, then clears and refocuses the field —
   one-shot commands riding the insert's transaction; the clear's own
   text_changed "" re-enters through the fold and empties the draft,
   so a second add finds nothing to add.

   Build like milestone2.hs, then run with KAYA_SELFTEST=entry. -}

import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..), kindButton, kindColumn, kindEntry, kindLabel)

main :: IO ()
main = kayaMain $ \app -> do
  (status, field, add, todos) <- buildTx app $ do
    status <- signal (VStr "no todos")

    column <- widget kindColumn
    field <- widget kindEntry
    add <- widget kindButton
    setText add "add"
    statusLabel <- widget kindLabel
    bindText statusLabel status

    todos <- collection
    (todoList, ()) <- forEach todos $ do
      label <- widget kindLabel
      bindTextElement label 0

    addChild column field
    addChild column add
    addChild column statusLabel
    addChild column todoList
    mount column
    return (status, field, add, todos)

  -- The fold: widget-owned state arrives as occurrences; the app's
  -- copy is this IORef, not a widget read.
  draftRef <- newIORef ""
  keyRef <- newIORef (0 :: Int)
  onChange app field $ \text -> writeIORef draftRef text
  onClick app add $ do
    draft <- readIORef draftRef
    -- The empty-draft guard every real form has — and the scene's
    -- proof that clear emptied the draft through the occurrence fold,
    -- not a side assignment.
    if null draft
      then submitTx app $ do
        total <- count todos
        writeSignal status (VStr ("nothing to add, " ++ show total ++ " total"))
      else do
        key <- atomicModifyIORef' keyRef (\n -> (n + 1, n + 1))
        submitTx app $ do
          insert todos (VStr ("t" ++ show key)) (VStr draft)
          total <- count todos
          writeSignal status (VStr ("added " ++ draft ++ ", " ++ show total ++ " total"))
          -- Finish the form: drop the field's content and put the
          -- cursor back, atomically with the insert. The field answers
          -- with text_changed "" through its normal edit path, and the
          -- fold above empties the draft.
          clearWidget field
          focusWidget field
