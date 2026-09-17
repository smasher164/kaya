{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The pickers scene, Haskell port — guests/rust/pickers.rs,
-- tools/scenes/pickers.steps, docs/datetime-plan.md.

import Data.Time.Calendar (Day, fromGregorian, toGregorian)
import Data.Time.LocalTime (TimeOfDay (..))
import GHC.Generics (Generic)
import Text.Printf (printf)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Task = Task {name :: Text, due :: Day}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


-- printf is String by nature (Text.Printf has no Text instance), so the
-- one conversion sits here rather than at every call.
dayText :: Day -> Text
dayText d = let (y, m, dd) = toGregorian d in T.pack (printf "%04d-%02d-%02d" y m dd)

clockText :: TimeOfDay -> Text
clockText t = T.pack (printf "%02d:%02d" (todHour t) (todMin t))

keyWord :: Key -> Text
keyWord = keyText

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    dateText <- signalText "date: none"
    timeText <- signalText "time: none"
    rowText <- signalText "row: none"
    dateSig <- signalDate ((fromGregorian 2026 9 4))
    timeSig <- signalTime ((TimeOfDay 14 30 0))
    tasks <- collectionOf @Task

    let onDate picked =
          submitTx app $ writeSignal dateText ("date: " <> dayText picked)
        onTime picked =
          submitTx app $ writeSignal timeText ("time: " <> clockText picked)
        onRowDate (key : _) picked =
          submitTx app $
            writeSignal
              rowText
              ("row " <> keyWord key <> ": " <> dayText picked)
        onRowDate [] _ = error "kaya: onRowDate's key path is never empty"
        onReset = submitTx app $ do
          writeSignal dateSig ((fromGregorian 2026 3 1))
          writeSignal timeSig ((TimeOfDay 9 0 0))

    root <-
      column
        [ labelBound dateText, -- label#0
          labelBound timeText, -- label#1
          labelBound rowText, -- label#2
          datePickerBoundOn -- date_picker#0
            dateSig
            onDate
            [ MinDate (fromGregorian 2026 1 1),
              MaxDate (fromGregorian 2026 12 31),
              A11yId "when",
              A11yLabel "Due"
            ],
          timePickerBoundOn -- time_picker#0
            timeSig
            onTime
            [MinuteStep 15, A11yId "at", A11yLabel "At"],
          buttonOn "reset" onReset, -- button#0
          each (recordHandle tasks) $
            rowOf
              [ label (field @"name" @Task),
                withTplAttrs
                  [TplA11yId "due"]
                  (datePicker (field @"due" @Task) onRowDate)
              ]
        ]
    mount root

    insertRecord tasks "a" (Task "a" (fromGregorian 2026 10 1))
    insertRecord tasks "b" (Task "b" (fromGregorian 2026 11 20))
