{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The pickers scene, Haskell port — guests/rust/pickers.rs,
-- tools/scenes/pickers.steps, docs/datetime-plan.md.

import Data.Proxy (Proxy (..))
import Data.Time.Calendar (Day, fromGregorian, toGregorian)
import Data.Time.LocalTime (TimeOfDay (..))
import GHC.Generics (Generic)
import Text.Printf (printf)

import KayaApp
import KayaWire (Value (..))

data Task = Task {name :: String, due :: Day} deriving (Generic)

instance KayaRecord Task

dayText :: Day -> String
dayText d = let (y, m, dd) = toGregorian d in printf "%04d-%02d-%02d" y m dd

clockText :: TimeOfDay -> String
clockText t = printf "%02d:%02d" (todHour t) (todMin t)

keyWord :: Value -> String
keyWord v = case v of VStr s -> s; other -> show other

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    dateText <- signal (VStr "date: none")
    timeText <- signal (VStr "time: none")
    rowText <- signal (VStr "row: none")
    dateSig <- signal (dateValue (fromGregorian 2026 9 4))
    timeSig <- signal (timeValue (TimeOfDay 14 30 0))
    tasks <- collectionOf (Proxy :: Proxy Task)

    let onDate picked =
          submitTx app $ writeSignal dateText (VStr ("date: " ++ dayText picked))
        onTime picked =
          submitTx app $ writeSignal timeText (VStr ("time: " ++ clockText picked))
        onRowDate keys picked =
          submitTx app $
            writeSignal
              rowText
              (VStr ("row " ++ keyWord (head keys) ++ ": " ++ dayText picked))
        onReset = submitTx app $ do
          writeSignal dateSig (dateValue (fromGregorian 2026 3 1))
          writeSignal timeSig (timeValue (TimeOfDay 9 0 0))

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

    insertRecord tasks (VStr "a") (Task "a" (fromGregorian 2026 10 1))
    insertRecord tasks (VStr "b") (Task "b" (fromGregorian 2026 11 20))
