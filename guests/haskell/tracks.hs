{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The tracks scene, Haskell port — guests/rust/tracks.rs,
-- tools/scenes/tracks.steps, docs/styling-pass-plan.md Y5-Y7.

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Track = Track
  { number :: Text,
    title :: Text,
    artist :: Text,
    album :: Text,
    art :: BS.ByteString,
    tint :: Tint,
    selected :: Bool
  }
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

playlistLength, playing :: Int
playlistLength = 60
playing = 3

names :: [(Text, Text, Text)]
names =
  [ ("Blue in Green", "Miles Davis", "Kind of Blue"),
    ("So What", "Miles Davis", "Kind of Blue"),
    ("Naima", "John Coltrane", "Giant Steps")
  ]

table :: RecordCollection Track -> Text -> Text -> ([Key] -> IO ()) -> Build Widget
table tracks ident rowId open = do
  (list, _) <- forEach (recordHandle tracks) $
    withTplAttrs
      [TplA11yId rowId, TplSelectedField (field @"selected" @Track), TplOnActivate open]
      ( rowOf
          [ label (field @"number" @Track),
            rowOf
              [ withTplAttrs
                  [TplFitAs FitCover, TplMaxWidth 40, TplMaxHeight 40, TplShapeAs ShapeRounded, TplA11yId "art"]
                  (image (field @"art" @Track)),
                columnOf
                  [ withTplAttrs [TplTintField (field @"tint" @Track), TplA11yId "name"] (label (field @"title" @Track)),
                    caption (field @"artist" @Track)
                  ]
              ],
            label (field @"album" @Track)
          ]
      )
  columns list ["#", "Title", "Album"] sortNone
  setA11yId list ident
  return list

track :: Int -> BS.ByteString -> Track
track i bytes =
  let (t, a, al) = names !! (i `mod` length names)
   in Track (tshow (i + 1)) t a al bytes (if i + 1 == playing then TintAccent else TintNone) False

main :: IO ()
main = kayaMain $ \app -> do
  bytes <- asset "covers/cover-600.jpg" >>= assetBytes
  buildTx app $ do
    window primary [WTitle "tracks", WSize 720 640]
    albumRows <- collectionOf @Track
    playlist <- collectionOf @Track
    let open keys = case keys of
          picked : _ -> submitTx app $ do
            forM_ [0 .. length names - 1] $ \i ->
              let key = textKey ("a" <> tshow (i + 1))
               in patch albumRows key [set (field @"selected" @Track) (key == picked)]
            forM_ [0 .. playlistLength - 1] $ \i ->
              let key = textKey ("t" <> tshow (i + 1))
               in patch playlist key [set (field @"selected" @Track) (key == picked)]
          [] -> return ()
    albumTable <- table albumRows "album" "a" open
    long <- table playlist "tracks" "t" open
    setGrow long 1
    root <- column [Spacing 12] [pure albumTable, pure long]
    mount root
    forM_ [0 .. length names - 1] $ \i -> insertRecord albumRows (textKey ("a" <> tshow (i + 1))) (track i bytes)
    forM_ [0 .. playlistLength - 1] $ \i -> insertRecord playlist (textKey ("t" <> tshow (i + 1))) (track i bytes)
