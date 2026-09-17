{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The reorder scene, Haskell port — guests/rust/reorder.rs,
-- tools/scenes/reorder.steps.

import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Item = Item {title :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    items <- collectionOf @Item

    let onRotate = submitTx app $ do
          entries <- recordItems items
          case entries of
            (firstKey, _) : _ -> moveToEnd (recordHandle items) firstKey
            [] -> return ()
        onLift = submitTx app $ do
          -- Keys, never indices.
          entries <- recordItems items
          case reverse entries of
            (lastKey, _) : _ -> moveToFront (recordHandle items) lastKey
            [] -> return ()

    root <-
      row
        [ buttonOn "rotate" onRotate,
          buttonOn "lift" onLift,
          each (recordHandle items) $ label (field @"title" @Item)
        ]
    mount root
    mapM_ (\k -> insertRecord items k (Item k)) ["a", "b", "c"]
