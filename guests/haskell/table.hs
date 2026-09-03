{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The table scene, Haskell port — guests/rust/table.rs,
-- tools/scenes/table.steps.

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data TableItem = TableItem {name :: String, size :: String} deriving (Generic)

instance KayaRecord TableItem

main :: IO ()
main = kayaMain $ \app -> do
  -- The guest's sort policy; the platform never has one.
  sorted <- newIORef (Nothing :: Maybe (Int, Bool))
  (items, table) <- buildTx app $ do
    items <- collectionOf (Proxy :: Proxy TableItem)
    -- The root is a row so the For's container is the scene's only
    -- column-kind widget (the reorder scene's rule).
    (table, _) <-
      forEach (recordHandle items) $
        rowOf
          [ label (field @"name" @TableItem),
            label (field @"size" @TableItem)
          ]
    -- Grown on purpose: ungrown would hug its rows (docs/tables-plan.md
    -- decision 8).
    setGrow table 1
    columns table ["Name", "Size"] sortNone
    root <- row [pure table]
    mount root
    mapM_
      (\(k, n, s) -> insertRecord items (VStr k) (TableItem n s))
      [("b", "banana", "30"), ("a", "apple", "10"), ("c", "cherry", "20")]
    return (items, table)
  onSort app table $ \column -> do
    current <- readIORef sorted
    let desc = case current of
          Just (c, d) -> c == column && not d
          _ -> False
    writeIORef sorted (Just (column, desc))
    submitTx app $ do
      entries <- recordItems items
      let keyOf (_, item) = if column == 0 then name item else size item
          ordered0 = sortBy (comparing keyOf) entries
          ordered = if desc then reverse ordered0 else ordered0
      -- Keys, never indices.
      mapM_ (\(k, _) -> moveToEnd (recordHandle items) k) ordered
      columns table ["Name", "Size"] $
        if desc then sortDesc column else sortAsc column
