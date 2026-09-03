{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The reorder scene, Haskell port — guests/rust/reorder.rs,
-- tools/scenes/reorder.steps.

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
          entries <- recordItems items
          let (firstKey, _) = head entries
          moveToEnd (recordHandle items) firstKey
        onLift = submitTx app $ do
          -- Keys, never indices.
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
