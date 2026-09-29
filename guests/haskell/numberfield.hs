{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The number field scene, Haskell port — guests/rust/numberfield.rs,
-- tools/scenes/numberfield.steps, docs/number-field-plan.md.

import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (isSuffixOf)
import GHC.Generics (Generic)
import Text.Printf (printf)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Line = Line {name :: Text, qty :: Double}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

-- The harness's own value spelling (crates/kaya/src/harness.rs).
-- printf is String by nature (Text.Printf has no Text instance), so the
-- one conversion sits here rather than at every call.
spelled :: Double -> Text
spelled v = T.pack (dropDot (dropZeros (printf "%.6f" v)))
  where
    dropZeros s = if "0" `isSuffixOf` s then dropZeros (init s) else s
    dropDot s = if "." `isSuffixOf` s then init s else s

main :: IO ()
main = kayaMain $ \app -> do
  commitsRef <- newIORef (0 :: Int)

  (rowText, qtyNode) <- buildTx app $ do
    commitText <- signalText "commits: 0"
    rowText <- signalText "row: none"
    amountValue <- signalDouble 0.0
    lines' <- collectionOf @Line

    let onCommitted _ = do
          n <- atomicModifyIORef' commitsRef (\c -> (c + 1, c + 1))
          submitTx app $ writeSignal commitText ("commits: " <> tshow n)
        onForty =
          -- Must NOT come back as a commit.
          submitTx app $ writeSignal amountValue (40.0 :: Double)

    (lineList, qtyNode) <- forEach (recordHandle lines') $ do
      -- Realized ahead of its row so the central registration has a handle.
      n <-
        withTplAttrs
          [TplMin 0.0, TplA11yId "qty"]
          (numberField (field @"qty" @Line))
      _ <- rowOf [label (field @"name" @Line), pure n]
      return n

    root <-
      column
        [ labelBound commitText [A11yId "commits"],
          labelBound rowText [A11yId "row"],
          numberFieldBoundOn
            amountValue
            onCommitted
            [Min 0.0, Max 100.0, Step 0.5, A11yId "amount", A11yLabel "Amount"],
          entry [A11yId "note"],
          buttonOn "forty" onForty [A11yId "forty"],
          pure lineList
        ]
    mount root

    insertRecord lines' "a" (Line "a" 1.0)
    insertRecord lines' "b" (Line "b" 2.0)
    return (rowText, qtyNode)

  onValueCommitted app qtyNode $ \keys v -> case keys of
    (key : _) ->
      submitTx app $
        writeSignal rowText ("row " <> keyText key <> ": " <> spelled v)
    [] -> error "kaya: onValueCommitted's key path is never empty"
