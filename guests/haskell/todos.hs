{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The todos scene, Haskell port — guests/rust/todos.rs,
-- tools/scenes/todos.steps.

import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Todo = Todo {title :: Text, done :: Bool}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ("" :: Text)

  buildTx app $ do
    window
      primary
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

    todos <- collectionOf @Todo
    -- The derive's write rides each mutation's transaction, so nothing here
    -- registers 'WOnUndone'.
    itemsLeft <-
      derive todos $ \entries ->
        let n = length (filter (not . done . snd) entries)
         in T.pack (if n == 1 then "1 item left" else show n ++ " items left")

    entryField <- entryOn (writeIORef draftRef)

    let onAdd = do
          draft <- readIORef draftRef
          if T.null draft
            then return ()
            else do
              undoableTx app ("add " <> draft) $ do
                _ <- insertFresh todos (Todo draft False)
                return ()
              -- 'clearWidget' inside a group is refused at apply
              -- (docs/undo-plan.md D4).
              submitTx app $ do
                clearWidget entryField
                focusWidget entryField
        onToggle (key : _) checked =
          submitTx app $
            patch todos key [set (field @"done" @Todo) checked]
        onToggle [] _ = error "kaya: onToggle's key path is never empty"

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
