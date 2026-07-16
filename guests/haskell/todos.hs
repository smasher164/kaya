{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The todos scene from Haskell, on the construction sugar: the type is
   the schema (deriving Generic + a KayaRecord instance), constructors
   carry their props and handlers, containers take their children, and
   the do-block reads as the tree. The sugar lowers eagerly to the same
   records as the explicit floor — milestone2.hs keeps that style on
   purpose.

   Build like milestone2.hs, then run with KAYA_SELFTEST=todos. -}

import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

-- The record is the schema.
data Todo = Todo {title :: String, done :: Bool} deriving (Generic)

instance KayaRecord Todo

main :: IO ()
main = kayaMain $ \app -> do
  -- The fold: widget-owned state arrives as occurrences; the app's
  -- copy is this IORef, not a widget read.
  draftRef <- newIORef ""
  keyRef <- newIORef (0 :: Int)

  buildTx app $ do
    itemsLeft <- signal (VStr "0 items left")
    todos <- collectionOf (Proxy :: Proxy Todo)

    let itemsLeftText = do
          entries <- recordItems todos
          let n = length (filter (not . done . snd) entries)
          return (if n == 1 then "1 item left" else show n ++ " items left")
        onAdd = do
          draft <- readIORef draftRef
          key <- atomicModifyIORef' keyRef (\n -> (n + 1, n + 1))
          submitTx app $ do
            insertRecord todos (VStr ("t" ++ show key)) (Todo draft False)
            status <- itemsLeftText
            writeSignal itemsLeft (VStr status)
        onToggle keys checked =
          submitTx app $ do
            -- One field's delta: the title never travels.
            patch todos (head keys) [set (field @"done" @Todo) checked]
            status <- itemsLeftText
            writeSignal itemsLeft (VStr status)

    root <-
      column
        [ entryOn (writeIORef draftRef),
          buttonOn "Add" onAdd,
          labelBound itemsLeft,
          each (recordHandle todos) $
            row
              [ checkbox (field @"done" @Todo) onToggle,
                label (field @"title" @Todo)
              ]
        ]
    mount root
