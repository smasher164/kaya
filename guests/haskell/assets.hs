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
  font <- asset fontName
  markBytes <- assetBytes mark
  fontBytes <- assetBytes font
  census <- firstLine <$> assetMissSentence missingName
  complaint <- assetMissSentence fontName
  let verdict = if null complaint then "no complaint" else firstLine complaint
      -- `show` on an Int consults no locale.
      summary =
        fontName ++ ": " ++ show (BS.length fontBytes) ++ " bytes, " ++ verdict
  buildTx app $ do
    window 0 [WTitle "assets", WSize 480 360]

    title <- signal (VStr "assets")
    found <- signal (VStr census)
    sizes <- signal (VStr summary)

    root <-
      column
        []
        [ labelBound title, -- label#0
          imageBytes markBytes, -- image#0
          labelBound found, -- label#1
          labelBound sizes -- label#2
        ]
    mount root
  assetClose mark
  assetClose font
