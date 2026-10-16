{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The cards scene, Haskell port — guests/rust/cards.rs,
-- tools/scenes/cards.steps, docs/styling-pass-plan.md Y4.

import Control.Monad (forM_)
import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Playlist = Playlist {name :: Text, selected :: Bool}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

cards :: [(Text, Text)]
cards = [("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly")]

libraryRows :: [(Text, Text)]
libraryRows = [("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus")]

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    window primary [WTitle "cards", WSize 520 520]
    status <- signalText "opened: none"
    library <- collectionOf @Playlist
    let card (ident, title) =
          column
            [ Filled TintNeutral,
              A11yId ident,
              OnActivate (submitTx app (writeSignal status ("opened: " <> title)))
            ]
            [labelText title, captionText "Made for you"]
        open keys = case keys of
          picked : _ -> submitTx app $
            forM_ libraryRows $ \(key, _) ->
              patch library (textKey key) [set (field @"selected" @Playlist) (textKey key == picked)]
          [] -> return ()
    (rows, _) <- forEach (recordHandle library) $
      withTplAttrs
        [TplA11yId "lib", TplSelectedField (field @"selected" @Playlist), TplOnActivate open]
        (rowOf [label (field @"name" @Playlist)])
    cardGrid <- grid 3 (map card cards)
    setSpacing cardGrid 12
    root <-
      column
        [Spacing 16]
        [ pure cardGrid,
          labelBound status [A11yId "status"],
          pure rows
        ]
    mount root
    forM_ libraryRows $ \(key, title) -> insertRecord library (textKey key) (Playlist title False)
