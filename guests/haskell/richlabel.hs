{-# LANGUAGE OverloadedStrings #-}

-- The rich label scene, Haskell port — guests/rust/richlabel.rs,
-- tools/scenes/richlabel.steps (docs/rich-text-plan.md R8, §15): a label
-- carries the inline vocabulary read-only — the app writes its document and
-- edits it, and the widget draws the runs over the role's own font. THE
-- OFFSETS ARE UTF-8 BYTES (docs/ranges-units.md).

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

docSource :: Text
docSource = "Héllo world, code"

-- The core's spelling of runs (`expect_runs`), so the binding's document
-- and the core's mirror are compared as one string.
spell :: [Run] -> Text
spell = T.intercalate "|" . map one
  where
    one r
      | runValue r == "true" = span_ r <> runName r
      | otherwise = span_ r <> runName r <> "=" <> runValue r
    span_ r = T.pack (show (runStart r) ++ ":" ++ show (runEnd r) ++ " ")

main :: IO ()
main = kayaMain $ \app -> buildTx app $ do
  window primary [WTitle "richlabel"]
  runs <- signal ("" :: Text)
  bodyText <- signal ("" :: Text)
  headingText <- signal ("Heading with italic" :: Text)

  -- Realized here because the buttons below need their handles.
  body <- labelBound bodyText [Rich True, A11yId ("body" :: Text)]
  heading <- labelBound headingText [Role Heading, Rich True, A11yId ("heading" :: Text)]

  root <-
    column
      []
      [ pure body, -- label#0
        pure heading, -- label#1
        labelBound runs [A11yId ("runs" :: Text)], -- label#2
        row
          []
          [ -- button#0 — the declaration: text and runs in one write
            buttonOn "seed" $ do
              let doc =
                    mark (14, 18) "code" "true"
                      . linkRun (7, 12) "https://kaya.dev"
                      . boldRun (0, 6)
                      $ documentOf docSource
                  title =
                    mark (13, 19) "italic" "true" (documentOf "Heading with italic")
              submitTx app $ do
                setDocument app body doc
                setDocument app heading title
                writeSignal runs (spell (docRuns doc)),
            -- button#1 — the app's own edit, italic over the inserted word
            buttonOn "insert" $ do
              submitTx app
                ( applyEdit app body
                    (markEdit (2, 5) "italic" "true" (insertEdit 6 ", big"))
                )
              doc <- document app body
              submitTx app (writeSignal runs (spell (docRuns doc))),
            -- button#2 — THE RANGED ACT ON A LABEL (docs/rich-text-plan.md
            -- §17): an italic over a range and the bold taken off another,
            -- the label's own document written by range.
            buttonOn "mark" $ do
              submitTx app $ do
                formatTextRange app body (1, 4) "italic" "true"
                unformatRange app body (0, 3) "bold" -- "Hé": byte 2 is inside the é
              doc <- document app body
              submitTx app (writeSignal runs (spell (docRuns doc)))
          ]
      ]
  mount root
