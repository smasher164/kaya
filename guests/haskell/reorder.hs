{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The reorder scene from Haskell: order as collection data, end to
   end. Three stamped rows and two buttons that never touch a widget —
   each handler repositions an entry by key (collection_move on the
   wire, move_child at the toolkit), and the selftest's expect_order
   reads the toolkit's actual child order back. The root is a row so
   the For's container is the scene's only column-kind widget:
   languages disagree on whether containers are created before or
   after their children, and column#0 must name the same widget
   everywhere.

   Build like milestone2.hs, then run with KAYA_SELFTEST=reorder. -}

import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

-- The record is the schema.
data Item = Item {title :: String} deriving (Generic)

instance KayaRecord Item

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    items <- collectionOf (Proxy :: Proxy Item)

    let onRotate = submitTx app $ do
          -- First entry to the end. The model owns the order, so the
          -- handler asks it which key is first — it never counts
          -- widgets.
          entries <- recordItems items
          let (firstKey, _) = head entries
          moveToEnd (recordHandle items) firstKey
        onLift = submitTx app $ do
          -- Last entry to the front: moveToFront is sugar for
          -- moveBefore the current first key — the same wire op, keys
          -- never indices.
          entries <- recordItems items
          let (lastKey, _) = last entries
          moveToFront (recordHandle items) lastKey

    root <-
      row
        [ buttonOn "rotate" onRotate,
          buttonOn "lift" onLift,
          each (recordHandle items) $ label (field @"title" @Item)
        ]
    mount root
    mapM_ (\k -> insertRecord items (VStr k) (Item k)) ["a", "b", "c"]
