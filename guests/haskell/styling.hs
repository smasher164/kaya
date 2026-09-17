{-# LANGUAGE OverloadedStrings #-}

-- The styling scene, Haskell port — guests/rust/styling.rs,
-- tools/scenes/styling.steps.

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> buildTx app $ do
  -- BEFORE THE FIRST MOUNT, per the set-once wall.
  brandAccent 0x3584E4
  window primary [WTitle "styling", WSize 480 360, WInset 0]

  -- The signals come first: a handler riding a constructor sees only what is
  -- already bound.
  heading <- signal (T.pack "Sections")
  status <- signal (T.pack "ready")

  root <-
    column
      []
      [ -- expect_ax resolves a target through its AUTHORED id.
        headingBound heading [A11yId ("title" :: Text)], -- label#0
        labelBound status, -- label#1
        buttonOn "Delete" -- button#0
          (submitTx app (writeSignal status (T.pack "deleted")))
          [Role Destructive, A11yId ("delete" :: Text)],
        buttonOn "Save" -- button#1
          (submitTx app (writeSignal status (T.pack "saved")))
          [Role Prominent, A11yId ("save" :: Text)],
        -- Declared so every backend's caption arm runs: no universal AX
        -- observable, so the walls are the arms' refusals.
        captionText "captioned" -- label#2
      ]
  mount root
