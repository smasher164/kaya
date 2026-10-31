{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The search scene, Haskell port — guests/rust/search.rs,
-- tools/scenes/search.steps. The app owns the predicate
-- (docs/search-plan.md S9) and each row hides in place
-- (docs/hidden-plan.md).

import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Item = Item {name :: Text, unmatched :: Bool}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


names :: [Text]
names = ["apple", "banana", "cherry", "mango"]

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    window primary [WTitle "search"]
    items <- collectionOf @Item
    count <- signalText (tshow (length names) <> " items")

    let onQuery text = do
          let query = T.toLower text
              wanted = filter (T.isInfixOf query) names
          submitTx app $ do
            mapM_
              (\k -> updateField items (textKey k) (field @"unmatched" @Item) (not (query `T.isInfixOf` k)))
              names
            writeSignal count $
              if T.null query
                then tshow (length names) <> " items"
                else tshow (length wanted) <> " of " <> tshow (length names) <> " match"

    find <- searchOn onQuery [Placeholder "Search", A11yId "find", A11yLabel "Find items"]
    countLabel <- labelBound count [A11yId "count"]
    -- The For IS the list: expect_order reads its label children.
    (list, _) <-
      forEach (recordHandle items) $
        withTplAttrs [TplHiddenField (field @"unmatched" @Item)] (label (field @"name" @Item))
    setA11yId list "list"
    root <- column [pure find, pure countLabel, pure list]
    mount root
    mapM_ (\k -> insertRecord items (textKey k) (Item k False)) names
