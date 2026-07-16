{- The milestone-2 scene from Haskell, on the construction sugar:
   scene declaration as a builder monad — constructors carry their
   props and handlers, containers take their children, and When and For
   are combinators taking do-blocks. Template bodies are Tpl, the live
   zone is Build, and the two element types (Node vs Widget) make
   mixing the zones a type error.

   Build the library first (cargo build), then:
       ghc -threaded -O -ibindings/haskell -o milestone2-hs \
           bindings/haskell/kaya_hs_stubs.c crates/kaya/examples/milestone2.hs \
           -L target/debug -lkaya -optl-Wl,-rpath,<abs path to target/debug> -}

import Data.IORef (atomicModifyIORef', newIORef)

import KayaApp
import KayaWire (Value (..), kindButton, kindLabel)

main :: IO ()
main = kayaMain $ \app -> do
  stepsRef <- newIORef (0 :: Int)

  (status, items, removeButton) <- buildTx app $ do
    status <- signal (VStr "step 0")
    extras <- signal (VBool False)

    (banner, ()) <- when_ extras $ do
      bannerLabel <- widget kindLabel
      setText bannerLabel "extras on"

    groups <- collection
    (groupList, (items, removeButton)) <- forEach groups $ do
      name <- widget kindLabel
      bindTextElement name 0

      items <- collection
      (itemList, removeButton) <- forEach items $ do
        text <- widget kindLabel
        bindTextElement text 0
        removeButton <- widget kindButton
        setText removeButton "remove"
        _ <- column [return text, return removeButton]
        return removeButton
      _ <- column [return name, return itemList]
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
          return banner,
          return groupList
        ]
    mount root
    return (status, items, removeButton)

  onClickNode app removeButton $ \keys -> case keys of
    [VStr group, VStr item] ->
      submitTx app $ do
        -- The instance handle names the target once; mutation and read
        -- hang off the same value. The collection is the model: the
        -- count read is the fold of the patches, this one included.
        let todos = items `at` VStr group
        remove todos (VStr item)
        left <- count todos
        writeSignal status (VStr ("removed " ++ group ++ "/" ++ item ++ ", " ++ show left ++ " left"))
    _ -> return ()
