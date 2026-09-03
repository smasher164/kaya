{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The todos scene, Haskell port — guests/rust/todos.rs,
-- tools/scenes/todos.steps.

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data Todo = Todo {title :: String, done :: Bool} deriving (Generic)

instance KayaRecord Todo

main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ""

  buildTx app $ do
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
    -- The derive's write rides each mutation's transaction, so nothing here
    -- registers 'WOnUndone'.
    itemsLeft <-
      derive todos $ \entries ->
        let n = length (filter (not . done . snd) entries)
         in VStr (if n == 1 then "1 item left" else show n ++ " items left")

    entryField <- entryOn (writeIORef draftRef)

    let onAdd = do
          draft <- readIORef draftRef
          if null draft
            then return ()
            else do
              undoableTx app ("add " ++ draft) $ do
                _ <- insertFresh todos (Todo draft False)
                return ()
              -- 'clearWidget' inside a group is refused at apply
              -- (docs/undo-plan.md D4).
              submitTx app $ do
                clearWidget entryField
                focusWidget entryField
        onToggle keys checked =
          submitTx app $
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
