-- The rich label scene, Haskell port — guests/rust/richlabel.rs,
-- tools/scenes/richlabel.steps (docs/rich-text-plan.md R8, §15): a label
-- carries the inline vocabulary read-only — the app writes its document and
-- edits it, and the widget draws the runs over the role's own font. THE
-- OFFSETS ARE UTF-8 BYTES (docs/ranges-units.md).

import Data.List (intercalate)

import KayaApp
import KayaWire (Value (..))

docSource :: String
docSource = "Héllo world, code"

-- The core's spelling of runs (`expect_runs`), so the binding's document
-- and the core's mirror are compared as one string.
spell :: [Run] -> String
spell = intercalate "|" . map one
  where
    one r
      | runValue r == "true" = span_ r ++ runName r
      | otherwise = span_ r ++ runName r ++ "=" ++ runValue r
    span_ r = show (runStart r) ++ ":" ++ show (runEnd r) ++ " "

main :: IO ()
main = kayaMain $ \app -> buildTx app $ do
  window 0 [WTitle "richlabel"]
  runs <- signal (VStr "")
  bodyText <- signal (VStr "")
  headingText <- signal (VStr "Heading with italic")

  -- Realized here because the buttons below need their handles.
  body <- labelBound bodyText [Rich True, A11yId "body"]
  heading <- labelBound headingText [Role Heading, Rich True, A11yId "heading"]

  root <-
    column
      []
      [ pure body, -- label#0
        pure heading, -- label#1
        labelBound runs [A11yId "runs"], -- label#2
        row
          []
          [ -- button#0 — the declaration: text and runs in one write
            buttonOn "seed" $ do
              let doc =
                    mark (14, 18) "code" "true"
                      . linkRun (7, 12) "https://kaya.dev"
                      . bold (0, 6)
                      $ documentOf docSource
                  title =
                    mark (13, 19) "italic" "true" (documentOf "Heading with italic")
              submitTx app $ do
                setDocument app body doc
                setDocument app heading title
                writeSignal runs (VStr (spell (docRuns doc))),
            -- button#1 — the app's own edit, italic over the inserted word
            buttonOn "insert" $ do
              submitTx app
                ( applyEdit app body
                    (markEdit (2, 5) "italic" "true" (insertEdit 6 ", big"))
                )
              doc <- document app body
              submitTx app (writeSignal runs (VStr (spell (docRuns doc))))
          ]
      ]
  mount root
