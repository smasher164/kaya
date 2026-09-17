{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}
-- A key path's wire tag (KayaWire.Value) has no spelling a guest may
-- write (tools/check-sugar-surface.py's wire-tag clause) — the
-- fromWire-decoding helper below is left unsigned so its argument
-- type is inferred, never named.

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


dayText :: Day -> String
dayText d = let (y, m, dd) = toGregorian d in printf "%04d-%02d-%02d" y m dd

clockText :: TimeOfDay -> String
clockText t = printf "%02d:%02d" (todHour t) (todMin t)

-- The key path's own wire tag decoded through 'fromWire', never named:
-- the argument's type (the wire's Value) has no spelling a guest may
-- write (tools/check-sugar-surface.py's wire-tag clause).
keyWord v = T.unpack (fromWire v :: Text)

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    dateText <- signal (T.pack "date: none")
    timeText <- signal (T.pack "time: none")
    rowText <- signal (T.pack "row: none")
    dateSig <- signal (dateValue (fromGregorian 2026 9 4))
    timeSig <- signal (timeValue (TimeOfDay 14 30 0))
    tasks <- collectionOf @Task

    let onDate picked =
          submitTx app $ writeSignal dateText (T.pack ("date: " ++ dayText picked))
        onTime picked =
          submitTx app $ writeSignal timeText (T.pack ("time: " ++ clockText picked))
        onRowDate (key : _) picked =
          submitTx app $
            writeSignal
              rowText
              (T.pack ("row " ++ keyWord key ++ ": " ++ dayText picked))
        onRowDate [] _ = error "kaya: onRowDate's key path is never empty"
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
              A11yId ("when" :: Text),
              A11yLabel ("Due" :: Text)
            ],
          timePickerBoundOn -- time_picker#0
            timeSig
            onTime
            [MinuteStep 15, A11yId ("at" :: Text), A11yLabel ("At" :: Text)],
          buttonOn "reset" onReset, -- button#0
          each (recordHandle tasks) $
            rowOf
              [ label (field @"name" @Task),
                withTplAttrs
                  [TplA11yId ("due" :: Text)]
                  (datePicker (field @"due" @Task) onRowDate)
              ]
        ]
    mount root

    insertRecord tasks (T.pack "a") (Task "a" (fromGregorian 2026 10 1))
    insertRecord tasks (T.pack "b") (Task "b" (fromGregorian 2026 11 20))
