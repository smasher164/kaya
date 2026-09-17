{-# LANGUAGE OverloadedStrings #-}

-- The milestone2 scene, Haskell port — guests/rust/milestone2.rs,
-- tools/scenes/milestone2.steps.

import Data.IORef (atomicModifyIORef', newIORef)

import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  stepsRef <- newIORef (0 :: Int)

  (status, items, removeButton) <- buildTx app $ do
    status <- signalText "step 0"
    extras <- signalBool False

    (banner, _) <- when_ extras (labelText "extras on")

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
                insert groups "g1" "Work"
                let todos = items `at` "g1"
                insert todos "a" "send report"
                insert todos "b" "buy milk"
              2 -> do
                insert groups "g2" "Home"
                insert (items `at` "g2") "a" "water plants"
                update groups "g1" "Office"
              _ -> return ()
            writeSignal extras (n == 1)
            writeSignal status ("step " <> tshow n)

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
      submitTx app $ do
        let todos = items `at` groupV
        remove todos itemV
        left <- count todos
        writeSignal status
          ( "removed " <> keyText groupV <> "/" <> keyText itemV
              <> ", " <> tshow left <> " left" )
    _ -> return ()
