{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

import Control.Monad (unless)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Int (Int64)
import GHC.Generics (Generic)
import KayaApp

data Line = Line {qty :: Double}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

main :: IO ()
main = kayaMain $ \app -> do
  let normal = TimecodeRate 25 1 False
      dropRate = TimecodeRate 30000 1001 True
  initial <- fmtTimecode normal 93087
  parsed <- fmtParseTimecode normal "٠١:٠٢:٠٣:١٢"
  skipped <- fmtParseTimecode dropRate "00:01:00;00"
  nul <- fmtParseTimecode normal "00:00:00:00\0ignored"
  unless (parsed == Just 93087 && skipped == Nothing && nul == Nothing) $
    error "timecode parse door disagrees"
  commits <- newIORef (0 :: Int)
  phase <- newIORef (0 :: Int)
  (rowStatus, rowNode) <- buildTx app $ do
    window primary [WTitle "Timecode", WSize 440 500]
    status <- signalText "commits: 0"
    rowStatus <- signalText "row: none"
    playhead <- signalText initial
    rows <- collectionOf @Line
    let committed frames = do
          n <- atomicModifyIORef' commits (\c -> (c + 1, c + 1))
          text <- fmtTimecode normal (round frames)
          submitTx app $ do
            writeSignal status ("commits: " <> tshow n)
            writeSignal playhead text
    (rowList, rowNode) <- forEach (recordHandle rows) $ do
      node <- withTplAttrs [TplNumberFormat (Timecode normal), TplA11yId "rowtime"]
        (numberField (field @"qty" @Line))
      _ <- rowOf [pure node]
      return node
    switchingValue <- signalDouble (-2)
    switching <- numberFieldBound switchingValue [A11yId "switching"]
    let switchFormat = do
          p <- atomicModifyIORef' phase (\n -> (n + 1, n `mod` 4))
          submitTx app $ case p of
            0 -> setNumberFormat switching (Timecode dropRate) >> writeSignal switchingValue (1800 :: Double)
            1 -> writeSignal switchingValue (-2 :: Double) >> setNumberFormat switching Number
            2 -> writeSignal switchingValue (1800 :: Double) >> setNumberFormat switching (Timecode dropRate)
            _ -> setNumberFormat switching Number >> writeSignal switchingValue (-2 :: Double)
    root <- column [
      labelText "25 fps",
      labelBound playhead [A11yId "playhead"],
      numberFieldOn 93087 committed [NumberFormat (Timecode normal), A11yId "position", A11yLabel "Position"],
      labelBound status [A11yId "commits"],
      labelText "29.97 drop-frame",
      numberFieldOn 1799 committed [NumberFormat (Timecode dropRate), A11yId "drop", A11yLabel "Drop frame"],
      entry [A11yId "note"],
      pure rowList,
      labelBound rowStatus [A11yId "row"],
      pure switching,
      buttonOn "Switch format" switchFormat [A11yId "switchformat"]]
    mount root
    insertRecord rows "a" (Line 25)
    return (rowStatus, rowNode)
  onValueCommitted app rowNode $ \keys frames -> case keys of
    key : _ -> submitTx app $ writeSignal rowStatus
      ("row " <> keyText key <> ": " <> tshow (round frames :: Int64))
    [] -> error "kaya: onValueCommitted's key path is never empty"
