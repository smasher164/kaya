{- The milestone-2 scene from Haskell, on the construction sugar:
   scene declaration as a builder monad — constructors carry their
   props and handlers, containers take their children, and When and For
   are combinators taking do-blocks. Template bodies are Tpl, the live
   zone is Build, and the two element types (Node vs Widget) make
   mixing the zones a type error.

   WHAT THIS SCENE DOCUMENTS IS HOW A STAMPED WIDGET'S CLICK COMES
   BACK. The remove button is ONE declaration whose copies are as many
   as there are items, so its handler is registered CENTRALLY after the
   build — 'onClickNode app removeButton', against the node the
   template body handed out — and each click arrives naming the copy by
   its key path. todos.hs and undo.hs register theirs at the
   constructor instead; both spellings land in the same table, and this
   is the file where the other one is written down. Construction here
   is the ordinary sugar every example but the C guests uses (DESIGN.md,
   scope ratified 2026-08-05): the carve-out is the event mechanism,
   not the tree.

   IT IS ALSO WHY BOTH FORS KEEP THEIR RESULTS. A central registration
   needs a handle to name, and the per-group items collection has to
   escape too; 'forEach' hands the body's result back, while 'each' —
   the For-as-a-child sugar — discards it.

   AND THE APP NAMES ITS OWN GROUPS AND ITEMS. "g1" and "a" are
   identity this scene chose and reaches back for: g1 is renamed at
   step 2, g2/a is what the click removes and what the status line then
   says out loud. 'insertFresh' — the minter entry.hs and todos.hs use
   for a line of text that identifies nothing — would be the wrong tool
   here.

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

    -- A group IS its name and an item IS its line of text: both
    -- collections carry one field and the element is it, which is what
    -- 'element' addresses in the two templates below (a record's twin
    -- is 'field @"title" @Todo').
    groups <- collection
    (groupList, (items, removeButton)) <- forEach groups $ do
      items <- collection
      (itemList, removeButton) <- forEach items $ do
        -- The stamped button, realized ahead of its row so the central
        -- registration has a handle to name; 'pure' slots it into the
        -- column where it stands.
        removeButton <- button "remove"
        _ <- column [label element, pure removeButton]
        return removeButton
      _ <- column [label element, pure itemList]
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
        -- The instance handle names the target once; mutation and read
        -- hang off the same value. The collection is the model: the
        -- count read is the fold of the patches, this one included.
        let todos = items `at` VStr group
        remove todos (VStr item)
        left <- count todos
        writeSignal status (VStr ("removed " ++ group ++ "/" ++ item ++ ", " ++ show left ++ " left"))
    _ -> return ()
