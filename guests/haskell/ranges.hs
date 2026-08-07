{- The text-ranges conformance scene, Haskell port: the three
   primitives an editor cannot write for itself — HIGHLIGHT a set of
   ranges, SELECT one, REVEAL one — driven by a search this file writes
   in five lines.

   THE FIVE LINES ARE THE POINT. kaya ships no find engine, no find bar
   and no regex dialect (docs/ranges-plan.md §3): what to decorate is
   the app's question, and every editor answers it differently. What no
   app can write for itself is the other half — colouring a run of a
   native text view, moving its selection, scrolling it into view — and
   that is exactly what the framework ships.

   THE OFFSETS ARE UTF-8 BYTE OFFSETS, AND HASKELL'S OWN UNIT IS NOT.
   This is the one thing this port has to say that guests/rust/ranges.rs
   does not: a Rust `String` is indexed in bytes, so `match_indices`
   hands that app the ranges kaya wants for free. A Haskell 'String' is
   a list of 'Char' — scalars — so the obvious spelling, an
   'Data.List.isPrefixOf' walk over the document, returns 51, 197 and
   747 where kaya's unit says 57, 203 and 753. SIX SHORT, EVERY TIME,
   because the document opens with a CJK word, and nothing downstream
   could tell: the offsets are legal, they are in range, they land on
   character boundaries, and they decorate the wrong six characters.
   So the search runs where the offsets live — over the document's UTF-8
   encoding, with 'BS.breakSubstring', which is also what a Haskell
   editor holds its buffer as. The same trap, one layer down, is the
   scene's whole reason for opening in Japanese: a backend that forwards
   kaya's byte offsets to a platform counting UTF-16 is six early too.

   WHAT EACH LEG PROVES, in the order the script runs them:
     * a set of three matches decorated at once, read back out of the
       platform's own accessibility tree;
     * one of them selected, likewise;
     * the third REVEALED — asserted `offscreen` first, so the leg
       cannot pass on a document that happened to fit;
     * a user's keystroke DROPPING the declared set (D2: ranges are
       app-owned and never tracked across an edit);
     * a `select_range` REFUSED because the user is mid-composition
       (D4), which is the one thing on this surface a backend is
       expected not to do.

   Canonical semantics in guests/rust/ranges.rs; the byte-frozen
   contract in tools/scenes/ranges.steps. -}

import qualified Data.ByteString as BS
import Data.ByteString.Builder (stringUtf8, toLazyByteString)
import qualified Data.ByteString.Lazy as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (intercalate)

import KayaApp
import KayaWire (Value (..))

-- The document, frozen — 813 bytes, byte-identical to the other seven
-- guests' copy. Three occurrences of `alpha` and nothing else
-- containing that substring; forty short lines, so the last match is
-- far below a 240x96 viewport and REVEAL has something to do. A list
-- and not a string with gaps: every line is one visible element, so a
-- lost `\n` cannot hide inside an escape.
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

-- The document as kaya sees it. The binding encodes every string it
-- sends with this same encoder (KayaWire's `stringUtf8`), so these are
-- the exact bytes the offsets below index.
utf8 :: String -> BS.ByteString
utf8 = BL.toStrict . toLazyByteString . stringUtf8

-- THE WHOLE SEARCH. Literal, forward, non-overlapping, in the byte
-- domain — half-open @(start, stop)@ pairs, which is what the three
-- range verbs take. An editor that wants case folding, word boundaries
-- or a regex dialect writes those here, in the app, where its users can
-- be told what they mean.
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
  -- The app's own copy of the document, which is the ONLY authority on
  -- what the offsets mean. It advances on every edit, exactly as an
  -- editor's buffer does — Build is a pure state monad, so the fold
  -- lives in an IORef out here rather than in the transaction.
  docRef <- newIORef document

  buildTx app $ do
    window 0 [WTitle "ranges"]
    -- Bound before the widgets that close over it: a handler riding a
    -- constructor can only see what the Build has already bound.
    status <- signal (VStr "0 matches")

    -- The editor. The a11y id is not decoration: every range assertion
    -- reads the platform's accessibility tree, and the id is how a leg
    -- finds this control there.
    editor <-
      textareaOn
        ( \text -> do
            writeIORef docRef text
            -- THE SEARCH RESULTS ARE STALE AND THE APP SAYS SO. kaya
            -- has already dropped the decorations — a declared set is
            -- bound to the text it was declared against — and this is
            -- the app agreeing rather than being told: an editor whose
            -- document moved has to search again before it can claim
            -- anything about where the matches are.
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
