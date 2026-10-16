{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The shapes scene, Haskell port — guests/rust/shapes.rs,
-- tools/scenes/shapes.steps, docs/styling-pass-plan.md Y6.

import qualified Data.ByteString as BS
import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Person = Person {name :: Text, face :: BS.ByteString, phase :: ImagePhase}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

main :: IO ()
main = kayaMain $ \app -> do
  art <- asset "covers/cover-600.jpg" >>= assetBytes
  photo <- asset "images/photo.jpg" >>= assetBytes
  buildTx app $ do
    window primary [WTitle "shapes", WSize 420 360]
    people <- collectionOf @Person
    (avatars, _) <- forEach (recordHandle people) $ do
      rowOf
        [ withTplAttrs
            [ TplFitAs FitCover,
              TplMaxWidth 48,
              TplMaxHeight 48,
              TplPhaseField (field @"phase" @Person),
              TplShapeAs ShapeCircle,
              TplA11yId "avatar"
            ]
            (image (field @"face" @Person)),
          label (field @"name" @Person)
        ]
    let pictured (ident, shape) = imageBytes art [MaxWidth 48, MaxHeight 48, FitAs FitCover, ShapeAs shape, A11yId ident]
    root <-
      column
        [Spacing 16]
        [ row
            [Spacing 16]
            ( map pictured [("rect", ShapeRect), ("rounded", ShapeRounded), ("circle", ShapeCircle)]
                ++ [imageBytes photo [MaxWidth 48, MaxHeight 48, ShapeAs ShapeCircle, A11yId "wide"]]
            ),
          pure avatars
        ]
    mount root
    insertRecord people "a1" (Person "Ada" BS.empty PhaseLoading)
