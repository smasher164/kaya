{- The assets conformance scene from Haskell (docs/assets-plan.md,
   ratified 2026-08-18). The byte-frozen contract is
   tools/scenes/assets.steps.

   THIS ONE PROVES THE BYTES. @asset@ has two redemptions and the
   typeface scene already covers the other — a font whose bytes go from
   the core's read straight to the platform's font machinery and never
   enter this guest's heap. Here the guest IS the consumer: @assetBytes@
   copies the mark out, @imageBytes@ hands them on, and the platform's own
   decoder answers 64x64 off the real view.

   THE MISS IS A QUESTION, NOT A @catch@. @assetMissSentence@ answers the
   same sentence @asset@ would raise with, without raising, and that is
   the only shape nine languages share: Swift's raise is a trap rather
   than an exception, so a Swift sibling cannot catch its own miss at all.

   LINE 1 ONLY. Line 2 of that sentence names the place the core resolved
   and the route that chose it, which a bundle, a device directory and a
   repo checkout spell three different ways; line 1 is the same
   everywhere, so it is the line a scene can freeze. -}

import qualified Data.ByteString as BS

import KayaApp
import KayaWire (Value (..))

-- Deliberately not there, and a LEGAL name — relative, one component
-- deep — so what comes back is the census sentence and not a name-fault
-- one.
missingName :: String
missingName = "icons/nope.png"

-- The one the mark is under, and the one the census must list.
markName :: String
markName = "icons/kaya-mark.png"

-- The large one: 111400 bytes, so a reader that truncated into a fixed
-- buffer shows up here rather than passing quietly.
fontName :: String
fontName = "fonts/sora-wght.ttf"

-- The census half of the sentence. Empty in, empty out.
firstLine :: String -> String
firstLine = takeWhile (/= '\n')

main :: IO ()
main = kayaMain $ \app -> do
  -- All of it out here rather than below: Build is a pure state monad,
  -- so every read the transaction needs happens before it opens.
  mark <- asset markName
  font <- asset fontName
  markBytes <- assetBytes mark
  fontBytes <- assetBytes font
  census <- firstLine <$> assetMissSentence missingName
  complaint <- assetMissSentence fontName
  let -- The other arm is never taken on a healthy lane, and it shows
      -- the sentence rather than a word about it: a failure here has to
      -- say what was measured.
      verdict = if null complaint then "no complaint" else firstLine complaint
      -- `show` on an Int consults no locale: no separator, no padding,
      -- the same bytes as the other seven languages produce.
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
          -- THE BYTES, not the blob redemption: this scene is the
          -- consumer, so what reaches the decoder is what assetBytes
          -- handed back.
          imageBytes markBytes, -- image#0
          labelBound found, -- label#1
          labelBound sizes -- label#2
        ]
    mount root
  -- Explicit, as the typeface scene's close is; nothing after this reads
  -- either handle.
  assetClose mark
  assetClose font
