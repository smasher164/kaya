{- The milestone-2 scene from Haskell, on the construction sugar:
   constructors carry their props and handlers, containers take their
   children, and When and For are combinators taking do-blocks. Template
   bodies are Tpl and the live zone is Build, and the two element types
   (Node vs Widget) make mixing the zones a type error.

   WHAT THIS SCENE DOCUMENTS IS HOW A STAMPED WIDGET'S CLICK COMES BACK.
   The remove button is ONE declaration, so its handler is registered
   CENTRALLY after the build ('onClickNode app removeButton'), and each
   click arrives naming the copy by its key path. Both Fors therefore
   keep their results: 'forEach' hands the body's result back, where
   'each' discards it.

   Build the library first (cargo build), then:
       ghc -threaded -O -ibindings/haskell -o milestone2-hs \
           bindings/haskell/kaya_hs_stubs.c guests/haskell/milestone2.hs \
           -L target/debug -lkaya -optl-Wl,-rpath,<abs path to target/debug> -}

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

    -- Both collections are scalar — the element IS the value — which is
    -- what 'element' addresses in the two templates below (a record's
    -- twin is 'field @"title" @Todo').
    groups <- collection
    (groupList, (items, removeButton)) <- forEach groups $ do
      items <- collection
      (itemList, removeButton) <- forEach items $ do
        -- Realized ahead of its row so the central registration has a
        -- handle to name; 'pure' slots it into the column where it
        -- stands.
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

  onClickNode app removeButton $ \keys -> case keys of
    [VStr group, VStr item] ->
      submitTx app $ do
        let todos = items `at` VStr group
        remove todos (VStr item)
        left <- count todos
        writeSignal status (VStr ("removed " ++ group ++ "/" ++ item ++ ", " ++ show left ++ " left"))
    _ -> return ()
