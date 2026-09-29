{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The colour picker scene, Haskell port — guests/rust/colorpicker.rs,
-- tools/scenes/colorpicker.steps, docs/color-picker-plan.md.

import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Swatch = Swatch {name :: Text, fill :: Color}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    titleText <- signalText "color: none"
    glazeText <- signalText "alpha: none"
    rowText <- signalText "row: none"
    titleSig <- signalColor (colorFromHex 0x336699FF)
    swatches <- collectionOf @Swatch

    let onTitle picked =
          submitTx app $ writeSignal titleText ("color: " <> colorText picked)
        onGlaze picked =
          submitTx app $ writeSignal glazeText ("alpha: " <> colorText picked)
        onRowFill (key : _) picked =
          submitTx app $
            writeSignal rowText ("row " <> keyText key <> ": " <> colorText picked)
        onRowFill [] _ = error "kaya: onRowFill's key path is never empty"
        -- Must NOT come back as a Title occurrence.
        onReset = submitTx app $ writeSignal titleSig (colorFromHex 0x3584E4FF)

    root <-
      column
        [ labelBound titleText, -- label#0
          labelBound glazeText, -- label#1
          labelBound rowText, -- label#2
          colorPickerBoundOn -- color_picker#0
            titleSig
            onTitle
            [A11yId "title", A11yLabel "Title colour"],
          colorPickerOn -- color_picker#1
            (colorFromHex 0x26A269FF)
            onGlaze
            [Alpha True, A11yLabel "Glaze"],
          buttonOn "reset" onReset, -- button#0
          each (recordHandle swatches) $
            rowOf
              [ label (field @"name" @Swatch),
                withTplAttrs
                  [TplA11yId "fill"]
                  (colorPicker (field @"fill" @Swatch) onRowFill)
              ]
        ]
    mount root

    insertRecord swatches "a" (Swatch "a" (colorFromHex 0xE66100FF))
    insertRecord swatches "b" (Swatch "b" (colorFromHex 0xF6D32DFF))
