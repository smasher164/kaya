{-# LANGUAGE OverloadedStrings #-}

-- The milestone2 scene, Haskell port — guests/rust/milestone2.rs,
-- tools/scenes/milestone2.steps.

import Data.IORef (atomicModifyIORef', newIORef)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  stepsRef <- newIORef (0 :: Int)

  (status, items, removeButton) <- buildTx app $ do
    status <- signal (T.pack "step 0")
    extras <- signal False

    (banner, _) <- when_ extras (label ("extras on" :: Text))

    groups <- collection
    (groupList, (items, removeButton)) <- forEach groups $ do
      items <- collection
      (itemList, removeButton) <- forEach items $ do
        -- Realized ahead of its row so the central registration has a handle.
        removeButton <- button "remove"
        _ <- columnOf [label element, pure removeButton]
        return removeButton
      _ <- columnOf [label element, pure itemList]
      return (items, removeButton)

    let onStep = do
          n <- atomicModifyIORef' stepsRef (\n -> (n + 1, n + 1))
          submitTx app $ do
            case n of
              1 -> do
                insert groups ("g1" :: Text) ("Work" :: Text)
                let todos = items `at` ("g1" :: Text)
                insert todos ("a" :: Text) ("send report" :: Text)
                insert todos ("b" :: Text) ("buy milk" :: Text)
              2 -> do
                insert groups ("g2" :: Text) ("Home" :: Text)
                insert (items `at` ("g2" :: Text)) ("a" :: Text) ("water plants" :: Text)
                update groups ("g1" :: Text) ("Office" :: Text)
              _ -> return ()
            writeSignal extras (n == 1)
            writeSignal status (T.pack ("step " ++ show n))

    root <-
      column
        [ buttonOn "step" onStep,
          labelBound status,
          pure banner,
          pure groupList
        ]
    mount root
    return (status, items, removeButton)

  onClick app removeButton $ \keys -> case keys of
    [groupV, itemV] ->
      let group = fromWire groupV :: Text
          item = fromWire itemV :: Text
       in submitTx app $ do
            let todos = items `at` group
            remove todos item
            left <- count todos
            writeSignal status ("removed " <> group <> "/" <> item <> ", " <> T.pack (show left) <> " left")
    _ -> return ()
