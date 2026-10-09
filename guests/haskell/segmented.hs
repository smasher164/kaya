{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The segmented control scene, Haskell port — guests/rust/segmented.rs,
-- tools/scenes/segmented.steps, docs/segmented-plan.md §5.

import Data.IORef (atomicModifyIORef', newIORef)
import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Habit = Habit {name :: Text, cadence :: Double}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

periods :: [Text]
periods = ["Day", "Week", "Month"]

views :: [(Text, Symbol)]
views = [("Info", SymbolInfo), ("Edit", SymbolEdit)]

cadences :: [Text]
cadences = ["Daily", "Weekly"]

main :: IO ()
main = kayaMain $ \app -> do
  heardRef <- newIORef (0 :: Int)

  (cadenceText, cadenceNode) <- buildTx app $ do
    window primary [WTitle "segmented"]
    period <- signalDouble 0.0
    periodText <- signalText "period: Day"
    heardText <- signalText "heard: 0"
    viewText <- signalText "view: Edit"
    cadenceText <- signalText "cadence: -"
    habits <- collectionOf @Habit

    let onPeriod index = do
          heard <- atomicModifyIORef' heardRef (\h -> (h + 1, h + 1))
          submitTx app $ do
            writeSignal period (fromIntegral index :: Double)
            writeSignal periodText ("period: " <> periods !! index)
            writeSignal heardText ("heard: " <> tshow heard)
        onReset =
          submitTx app $ do
            writeSignal period (0.0 :: Double)
            writeSignal periodText "period: Day"
        onView index =
          submitTx app $ writeSignal viewText ("view: " <> fst (views !! index))

    (habitList, cadenceNode) <- forEach (recordHandle habits) $ do
      n <-
        withTplAttrs
          [TplA11yId "cadence"]
          (segmented cadences (field @"cadence" @Habit))
      _ <- columnOf [label (field @"name" @Habit), pure n]
      return n

    root <-
      column
        [ segmentedBoundOn periods period onPeriod [A11yId "period", A11yLabel "Period"],
          labelBound periodText,
          labelBound heardText,
          buttonOn "Reset" onReset [A11yId "reset"],
          segmentedSymbolsOn views 1 onView [A11yId "view", A11yLabel "View"],
          labelBound viewText,
          labelBound cadenceText,
          pure habitList
        ]
    mount root

    insertRecord habits "read" (Habit "read" 1.0)
    insertRecord habits "walk" (Habit "walk" 0.0)
    return (cadenceText, cadenceNode)

  onValueChanged app cadenceNode $ \keys v -> case keys of
    (key : _) ->
      submitTx app $
        writeSignal cadenceText ("cadence " <> keyText key <> ": " <> cadences !! round v)
    [] -> error "kaya: onValueChanged's key path is never empty"
