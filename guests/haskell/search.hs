{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The search scene, Haskell port — guests/rust/search.rs,
-- tools/scenes/search.steps. The app owns the filter
-- (docs/search-plan.md S9): the visible set is a diff of removes and
-- inserts by key.

import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Item = Item {name :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


names :: [Text]
names = ["apple", "banana", "cherry", "mango"]

main :: IO ()
main = kayaMain $ \app -> do
  visible <- newIORef names
  buildTx app $ do
    items <- collectionOf @Item
    count <- signal (T.pack (show (length names) ++ " items"))

    let onQuery text = do
          shown <- readIORef visible
          let query = T.toLower text
              wanted = filter (T.isInfixOf query) names
          submitTx app $ do
            -- A DIFF, never clear-and-refill: only the rows whose
            -- membership changed move (docs/search-plan.md S9).
            mapM_
              (\k -> remove (recordHandle items) k)
              (filter (`notElem` wanted) shown)
            mapM_
              (\k -> insertRecord items k (Item k))
              (filter (`notElem` shown) wanted)
            -- Insertion order is arrival order, so a row coming back lands
            -- last; walking the wanted keys to the end in order puts the
            -- list back in `names` order.
            mapM_ (\k -> moveToEnd (recordHandle items) k) wanted
            writeSignal count $
              if T.null query
                then T.pack (show (length names) ++ " items")
                else T.pack (show (length wanted) ++ " of " ++ show (length names) ++ " match")
          writeIORef visible wanted

    find <- searchOn onQuery [Placeholder ("Search" :: Text), A11yId ("find" :: Text), A11yLabel ("Find items" :: Text)]
    countLabel <- labelBound count [A11yId ("count" :: Text)]
    -- The For IS the list: expect_order reads its label children.
    (list, _) <- forEach (recordHandle items) (label (field @"name" @Item))
    setA11yId list "list"
    root <- column [pure find, pure countLabel, pure list]
    mount root
    mapM_ (\k -> insertRecord items k (Item k)) names
