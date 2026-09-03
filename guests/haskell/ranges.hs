-- The ranges scene, Haskell port — guests/rust/ranges.rs,
-- tools/scenes/ranges.steps.

import qualified Data.ByteString as BS
import Data.ByteString.Builder (stringUtf8, toLazyByteString)
import qualified Data.ByteString.Lazy as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (intercalate)

import KayaApp
import KayaWire (Value (..))

-- Frozen — 813 bytes, byte-identical to every other guest's copy.
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

-- The binding encodes with this same encoder, so these are the exact bytes
-- the offsets index.
utf8 :: String -> BS.ByteString
utf8 = BL.toStrict . toLazyByteString . stringUtf8

-- The whole search: literal, forward, non-overlapping, in the byte domain.
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
  -- The offsets index this copy; Build is pure, so the fold is an IORef.
  docRef <- newIORef document

  buildTx app $ do
    window 0 [WTitle "ranges"]
    -- Bound before the widgets that close over it.
    status <- signal (VStr "0 matches")

    -- Every range assertion finds this control by its authored id.
    editor <-
      textareaOn
        ( \text -> do
            writeIORef docRef text
            -- A declared set is bound to the text it was declared against
            -- (docs/ranges-plan.md D2).
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
                      -- The SECOND match, so a leg can tell the selection
                      -- apart from "the first thing found".
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
