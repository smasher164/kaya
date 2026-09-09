-- The assets scene, Haskell port — guests/rust/assets.rs,
-- tools/scenes/assets.steps.

import qualified Data.ByteString as BS

import KayaApp
import KayaWire (Value (..))

-- Deliberately absent, and a LEGAL name: the answer is the census sentence.
missingName :: String
missingName = "icons/nope.png"

markName :: String
markName = "icons/kaya-mark.png"

-- SCENERY, and deliberately tiny: an image widget's intrinsic size drives
-- layout and the DECLARED mark is a user-supplied source of any size
-- (the images/ family's README). The mark is still opened.
pictureName :: String
pictureName = "images/a11y-logo.png"

-- 111400 bytes, so a reader that truncated into a fixed buffer shows here.
fontName :: String
fontName = "fonts/sora-wght.ttf"

firstLine :: String -> String
firstLine = takeWhile (/= '\n')

main :: IO ()
main = kayaMain $ \app -> do
  -- Out here: Build is a pure state monad, so every read the transaction
  -- needs happens before it opens.
  mark <- asset markName
  picture <- asset pictureName
  font <- asset fontName
  markBytes <- assetBytes mark
  pictureBytes <- assetBytes picture
  fontBytes <- assetBytes font
  census <- firstLine <$> assetMissSentence missingName
  complaint <- assetMissSentence fontName
  let verdict = if null complaint then "no complaint" else firstLine complaint
      -- `show` on an Int consults no locale.
      present = if BS.length markBytes > 0 then "present" else "missing"
      summary =
        markName ++ " " ++ present ++ ", " ++ fontName ++ ": "
          ++ show (BS.length fontBytes) ++ " bytes, " ++ verdict
  buildTx app $ do
    window 0 [WTitle "assets", WSize 480 360]

    title <- signal (VStr "assets")
    found <- signal (VStr census)
    sizes <- signal (VStr summary)

    root <-
      column
        []
        [ labelBound title, -- label#0
          imageBytes pictureBytes, -- image#0
          labelBound found, -- label#1
          labelBound sizes -- label#2
        ]
    mount root
  assetClose mark
  assetClose picture
  assetClose font
