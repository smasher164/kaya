{- The text-ranges conformance scene, Haskell port: HIGHLIGHT a set of
   ranges, SELECT one, REVEAL one.

   THE OFFSETS ARE UTF-8 BYTE OFFSETS AND HASKELL'S OWN UNIT IS NOT: a
   'String' is a list of 'Char', so an 'isPrefixOf' walk answers in
   scalars and is SIX SHORT on this document, which opens with a CJK
   word. The search therefore runs over the UTF-8 encoding, with
   'BS.breakSubstring'. The frozen numbers and what a UTF-16 counter
   would say instead are in tools/validate-mac.sh.

   Canonical semantics in guests/rust/ranges.rs; the byte-frozen
   contract in tools/scenes/ranges.steps. -}

import qualified Data.ByteString as BS
import Data.ByteString.Builder (stringUtf8, toLazyByteString)
import qualified Data.ByteString.Lazy as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (intercalate)

import KayaApp
import KayaWire (Value (..))

-- Frozen — 813 bytes, byte-identical to the other seven guests' copy.
-- Three occurrences of `alpha`; forty short lines, so the last match is
-- far below a 240x96 viewport and REVEAL has something to do.
document :: String
document =
  intercalate
    "\n"
    [ "line 00: 日本語 preface",
      "line 01: gamma kappa",
      "line 02: alpha beta gamma",
      "line 03: epsilon theta",
      "line 04: zeta nu",
      "line 05: eta zeta",
      "line 06: theta lambda",
      "line 07: iota delta",
      "line 08: kappa iota",
      "line 09: alpha eta theta",
      "line 10: mu eta",
      "line 11: nu mu",
      "line 12: beta epsilon",
      "line 13: gamma kappa",
      "line 14: delta gamma",
      "line 15: epsilon theta",
      "line 16: zeta nu",
      "line 17: eta zeta",
      "line 18: theta lambda",
      "line 19: iota delta",
      "line 20: kappa iota",
      "line 21: lambda beta",
      "line 22: mu eta",
      "line 23: nu mu",
      "line 24: beta epsilon",
      "line 25: gamma kappa",
      "line 26: delta gamma",
      "line 27: epsilon theta",
      "line 28: zeta nu",
      "line 29: eta zeta",
      "line 30: theta lambda",
      "line 31: iota delta",
      "line 32: kappa iota",
      "line 33: lambda beta",
      "line 34: mu eta",
      "line 35: nu mu",
      "line 36: beta epsilon",
      "line 37: alpha iota kappa",
      "line 38: delta gamma",
      "line 39: the last line"
    ]

needle :: String
needle = "alpha"

-- The binding encodes every string it sends with this same encoder, so
-- these are the exact bytes the offsets index.
utf8 :: String -> BS.ByteString
utf8 = BL.toStrict . toLazyByteString . stringUtf8

-- The whole search: literal, forward, non-overlapping, in the byte
-- domain — half-open @(start, stop)@ pairs, which is what the three
-- range verbs take.
findAll :: String -> String -> [(Int, Int)]
findAll haystack pattern = go 0 (utf8 haystack)
  where
    pat = utf8 pattern
    width = BS.length pat
    go base rest
      | BS.null found = []
      | otherwise = (at, at + width) : go (at + width) (BS.drop width found)
      where
        (before, found) = BS.breakSubstring pat rest
        at = base + BS.length before

main :: IO ()
main = kayaMain $ \app -> do
  -- The app's own copy of the document, the ONLY authority on what the
  -- offsets mean. Build is a pure state monad, so the fold lives in an
  -- IORef out here rather than in the transaction.
  docRef <- newIORef document

  buildTx app $ do
    window 0 [WTitle "ranges"]
    -- Bound before the widgets that close over it: a handler riding a
    -- constructor can only see what the Build has already bound.
    status <- signal (VStr "0 matches")

    -- The a11y id is how a leg finds this control in the platform's
    -- accessibility tree, which is where every range assertion reads.
    editor <-
      textareaOn
        ( \text -> do
            writeIORef docRef text
            -- kaya has already dropped the decorations: a declared set
            -- is bound to the text it was declared against
            -- (docs/ranges-plan.md D2), so the app re-searches.
            submitTx app (writeSignal status (VStr "0 matches"))
        )
        [A11yId "doc", A11yLabel "Document"]
    setText editor document

    root <-
      column
        [ pure editor, -- textarea#0
          labelBound status, -- label#0
          row
            [ buttonOn -- button#0
                "find"
                ( do
                    hits <- flip findAll needle <$> readIORef docRef
                    submitTx app $ do
                      highlightRanges editor hits
                      -- The second match, so a leg can tell the
                      -- selection apart from "the first thing found".
                      case drop 1 hits of
                        second : _ -> selectRange editor second
                        [] -> return ()
                      writeSignal status (VStr (show (length hits) ++ " matches"))
                ),
              buttonOn -- button#1
                "reveal last"
                ( do
                    hits <- flip findAll needle <$> readIORef docRef
                    case hits of
                      [] -> return ()
                      _ -> submitTx app (revealRange editor (last hits))
                ),
              buttonOn -- button#2
                "focus editor"
                (submitTx app (focusWidget editor)),
              buttonOn -- button#3
                "select first"
                ( do
                    hits <- flip findAll needle <$> readIORef docRef
                    case hits of
                      first : _ -> submitTx app (selectRange editor first)
                      [] -> return ()
                )
            ]
        ]
    mount root
