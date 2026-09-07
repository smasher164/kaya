{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The search scene, Haskell port — guests/rust/search.rs,
-- tools/scenes/search.steps. The app owns the filter
-- (docs/search-plan.md S9): the visible set is a diff of removes and
-- inserts by key.

import Data.Char (toLower)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data Item = Item {name :: String} deriving (Generic)

instance KayaRecord Item

names :: [String]
names = ["apple", "banana", "cherry", "mango"]

main :: IO ()
main = kayaMain $ \app -> do
  visible <- newIORef names
  buildTx app $ do
    items <- collectionOf (Proxy :: Proxy Item)
    count <- signal (VStr (show (length names) ++ " items"))

    let onQuery text = do
          shown <- readIORef visible
          let query = map toLower text
              wanted = filter (query `isInfixOf`) names
          submitTx app $ do
            -- A DIFF, never clear-and-refill: only the rows whose
            -- membership changed move (docs/search-plan.md S9).
            mapM_
              (\k -> remove (recordHandle items) (VStr k))
              (filter (`notElem` wanted) shown)
            mapM_
              (\k -> insertRecord items (VStr k) (Item k))
              (filter (`notElem` shown) wanted)
            -- Insertion order is arrival order, so a row coming back lands
            -- last; walking the wanted keys to the end in order puts the
            -- list back in `names` order.
            mapM_ (\k -> moveToEnd (recordHandle items) (VStr k)) wanted
            writeSignal count . VStr $
              if null query
                then show (length names) ++ " items"
                else show (length wanted) ++ " of " ++ show (length names) ++ " match"
          writeIORef visible wanted

    find <- searchOn onQuery [Placeholder "Search", A11yId "find", A11yLabel "Find items"]
    countLabel <- labelBound count [A11yId "count"]
    -- The For IS the list: expect_order reads its label children.
    (list, _) <- forEach (recordHandle items) (label (field @"name" @Item))
    setA11yId list "list"
    root <- column [pure find, pure countLabel, pure list]
    mount root
    mapM_ (\k -> insertRecord items (VStr k) (Item k)) names
