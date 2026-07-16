{-# LANGUAGE DeriveGeneric #-}

{- The todos scene from Haskell: records and field projection. The type
   is the schema — `deriving Generic` is the whole obligation; the
   KayaRecord instance derives the schema, both conversions, and the
   selector names for field tokens — the template binds each field to
   its own widget through typed tokens, and toggling a row sends one
   field's delta through updateField: the title never travels.

   Build like milestone2.hs, then run with KAYA_SELFTEST=todos. -}

import Data.IORef (newIORef, readIORef, writeIORef, atomicModifyIORef')
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..), kindButton, kindCheckbox, kindColumn, kindEntry,
                 kindLabel, kindRow)

-- The record is the schema.
data Todo = Todo {title :: String, done :: Bool} deriving (Generic)

instance KayaRecord Todo

-- The field tokens, checked against the type at startup.
fieldTitle :: KField String
fieldTitle = fieldOf (Proxy :: Proxy Todo) "title"

fieldDone :: KField Bool
fieldDone = fieldOf (Proxy :: Proxy Todo) "done"

itemsLeftText :: RecordCollection Todo -> Build String
itemsLeftText todos = do
  entries <- recordItems todos
  let n = length (filter (not . done . snd) entries)
  return (if n == 1 then "1 item left" else show n ++ " items left")

main :: IO ()
main = kayaMain $ \app -> do
  (itemsLeft, field, add, todos, check) <- buildTx app $ do
    itemsLeft <- signal (VStr "0 items left")

    column <- widget kindColumn
    field <- widget kindEntry
    add <- widget kindButton
    setText add "Add"
    status <- widget kindLabel
    bindText status itemsLeft

    todos <- collectionOf (Proxy :: Proxy Todo)
    (todoList, check) <- forEach (recordHandle todos) $ do
      row <- widget kindRow
      check <- widget kindCheckbox
      bindCheckedField check 0 fieldDone
      titleLabel <- widget kindLabel
      bindTextField titleLabel 0 fieldTitle
      addChild row check
      addChild row titleLabel
      return check

    addChild column field
    addChild column add
    addChild column status
    addChild column todoList
    mount column
    return (itemsLeft, field, add, todos, check)

  -- The fold: widget-owned state arrives as occurrences; the app's
  -- copy is this IORef, not a widget read.
  draftRef <- newIORef ""
  keyRef <- newIORef (0 :: Int)
  onChange app field $ \text -> writeIORef draftRef text
  onClick app add $ do
    draft <- readIORef draftRef
    key <- atomicModifyIORef' keyRef (\n -> (n + 1, n + 1))
    submitTx app $ do
      insertRecord todos (VStr ("t" ++ show key)) (Todo draft False)
      status <- itemsLeftText todos
      writeSignal itemsLeft (VStr status)
  onToggleNode app check $ \keys checked ->
    submitTx app $ do
      -- One field's delta: the title never travels.
      updateField todos (head keys) fieldDone checked
      status <- itemsLeftText todos
      writeSignal itemsLeft (VStr status)
