{-# LANGUAGE OverloadedStrings #-}

-- The formatter door and the catalog, Haskell port — guests/rust/format.rs,
-- tools/scenes/format.steps.

import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.LocalTime (TimeOfDay (..))
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  catalog "format"
  let d = fromGregorian 2026 9 7
      t = TimeOfDay 8 30 0
  dShort <- fmtDate Short d
  dMedium <- fmtDate Medium d
  dLong <- fmtDate Long d
  tShort <- fmtTime Short t
  dt <- fmtDateTime Medium d t
  n <- fmtNumber numberOptions 1234567.891
  p <- fmtPercent numberOptions 0.256
  c <- fmtCurrency 1234567.89 "USD"
  one <- tr "items" [("count", arg (1 :: Int))]
  three <- tr "items" [("count", arg (3 :: Int))]
  hello <- tr "greeting" [("name", arg ("Ada" :: Text))]
  tag <- (.localeTag) <$> locale
  buildTx app $ do
    -- Fourteen labels and a row: taller than the default window.
    window primary [WTitle "format", WSize 540 560]
    root <-
      column
        []
        [ labelText dShort, -- label#0
          labelText dMedium, -- label#1
          labelText dLong, -- label#2
          labelText tShort, -- label#3
          labelText dt, -- label#4
          labelText n, -- label#5
          labelText p, -- label#6
          labelText c, -- label#7
          labelText one, -- label#8
          labelText three, -- label#9
          labelText hello, -- label#10
          row [] [labelText "first", spacer, labelText "last"], -- row#0, label#11, label#12
          labelText tag -- label#13
        ]
    mount root
