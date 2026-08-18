{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The reorder scene from Haskell: order as collection data. Each
   handler repositions an entry BY KEY, never by index, and expect_order
   reads the toolkit's actual child order back.

   THE ROOT IS A ROW so the For's container is the scene's only
   column-kind widget: languages disagree on whether a container is
   created before or after its children, and column#0 must name the same
   widget everywhere.

   Build like milestone2.hs, then run with KAYA_SELFTEST=reorder. -}

import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data Item = Item {title :: String} deriving (Generic)

instance KayaRecord Item

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    items <- collectionOf (Proxy :: Proxy Item)

    let onRotate = submitTx app $ do
          -- The MODEL owns the order, so the handler asks it which key
          -- is first; it never counts widgets.
          entries <- recordItems items
          let (firstKey, _) = head entries
          moveToEnd (recordHandle items) firstKey
        onLift = submitTx app $ do
          -- moveToFront is sugar for moveBefore the current first key —
          -- the same wire op, keys never indices.
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
