-- The milestone2 scene, Haskell port — guests/rust/milestone2.rs,
-- tools/scenes/milestone2.steps.

import Data.IORef (atomicModifyIORef', newIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  stepsRef <- newIORef (0 :: Int)

  (status, items, removeButton) <- buildTx app $ do
    status <- signal (VStr "step 0")
    extras <- signal (VBool False)

    (banner, _) <- when_ extras (label "extras on")

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
                insert groups (VStr "g1") (VStr "Work")
                let todos = items `at` VStr "g1"
                insert todos (VStr "a") (VStr "send report")
                insert todos (VStr "b") (VStr "buy milk")
              2 -> do
                insert groups (VStr "g2") (VStr "Home")
                insert (items `at` VStr "g2") (VStr "a") (VStr "water plants")
                update groups (VStr "g1") (VStr "Office")
              _ -> return ()
            writeSignal extras (VBool (n == 1))
            writeSignal status (VStr ("step " ++ show n))

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
    [VStr group, VStr item] ->
      submitTx app $ do
        let todos = items `at` VStr group
        remove todos (VStr item)
        left <- count todos
        writeSignal status (VStr ("removed " ++ group ++ "/" ++ item ++ ", " ++ show left ++ " left"))
    _ -> return ()
