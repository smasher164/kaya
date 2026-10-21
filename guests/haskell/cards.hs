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

data Playlist = Playlist {name :: Text, selected :: Bool, symbol :: Symbol}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

cards :: [(Text, Text)]
cards = [("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly")]

-- The third card is taller, so the row's cards take its height (M16 (1)).
tall :: Text
tall = "card3"

-- Cut at two lines with the platform's ellipsis (M16 (2)).
blurbLabel :: Build Widget
blurbLabel = do
  w <- captionText "Fresh picks every Monday, from the artists you play the most and the ones they listen to" [A11yId "blurb"]
  setMaxLines w 2
  pure w

libraryRows :: [(Text, Text)]
libraryRows = [("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus")]

main :: IO ()
main = kayaMain $ \app -> do
  (library, play) <- buildTx app $ do
    window primary [WTitle "cards", WSize 520 520]
    status <- signalText "opened: none"
    library <- collectionOf @Playlist
    -- A section hidden by a When and an empty For take no space (M16 (3)).
    hidden <- signalBool False
    empty <- collectionOf @Playlist
    (hiddenBox, _) <- when_ hidden (labelText "never shown")
    (emptyRows, _) <- forEach (recordHandle empty) (rowOf [label (field @"name" @Playlist)])
    let card (ident, title) =
          column
            [ Filled TintNeutral,
              A11yId ident,
              OnActivate (submitTx app (writeSignal status ("opened: " <> title)))
            ]
            ([labelText title, captionText "Made for you"] ++ [blurbLabel | ident == tall])
        open keys = case keys of
          picked : _ -> submitTx app $
            forM_ libraryRows $ \(key, _) ->
              patch library (textKey key) [set (field @"selected" @Playlist) (textKey key == picked)]
          [] -> return ()
    (rows, play) <- forEach (recordHandle library) $ do
      item <-
        withTplAttrs
          [TplA11yId "lib", TplSelectedField (field @"selected" @Playlist), TplOnActivate open]
          (rowOf [label (field @"name" @Playlist)])
      play <- withTplAttrs [TplA11yId "go", TplSymbolField (field @"symbol" @Playlist)] (button "Play")
      _ <- rowOf [pure item, pure play]
      return play
    cardGrid <- grid 1 (map card cards)
    setSpacing cardGrid 12
    setColumnsAuto cardGrid 140
    setA11yId cardGrid "cards"
    let more = submitTx app $ within cardGrid [card ("card4", "Release Radar")]
    root <-
      column
        [Spacing 16]
        [ pure cardGrid,
          buttonOn "More" more [A11yId "more"],
          labelBound status [A11yId "status"],
          pure hiddenBox,
          pure emptyRows,
          labelText "end" [A11yId "end"],
          pure rows
        ]
    mount root
    forM_ libraryRows $ \(key, title) -> insertRecord library (textKey key) (Playlist title False SymbolPlay)
    return (library, play)
  onClick app play $ \keys -> case keys of
    played : _ -> submitTx app $
      forM_ libraryRows $ \(key, _) ->
        patch library (textKey key)
          [set (field @"symbol" @Playlist) (if textKey key == played then SymbolPause else SymbolPlay)]
    [] -> return ()
