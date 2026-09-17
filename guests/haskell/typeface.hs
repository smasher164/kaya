{-# LANGUAGE OverloadedStrings #-}

-- The typeface scene, Haskell port — guests/rust/typeface.rs,
-- tools/scenes/typeface.steps.

import Data.IORef (newIORef, readIORef, writeIORef)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ("" :: Text)
  -- Out here: Build is a pure state monad, so the one IO the brand call needs
  -- happens before the transaction opens.
  font <- asset "fonts/sora-wght.ttf"
  buildTx app $ do
    -- BEFORE THE FIRST MOUNT, per the set-once wall.
    brandTypeface "Sora" [TFontAsset font]
    window primary [WTitle "typeface", WSize 480 360]

    heading <- signal (T.pack "typeface")
    status <- signal (T.pack "ready")

    root <-
      column
        []
        [ -- The heading's text style OVERRIDES the root font, so this is
          -- the label a root-only lowering leaves in the system face.
          labelBound heading [Role Heading, A11yId ("title" :: Text)], -- label#0
          labelBound status, -- label#1
          -- A field AND a textarea, because the swap reaches them by
          -- DIFFERENT routes.
          entryOn (writeIORef draftRef), -- entry#0
          textarea, -- textarea#0
          buttonOn -- button#0
            "Go"
            ( do
                draft <- readIORef draftRef
                submitTx app (writeSignal status ("clicked " <> draft))
            )
        ]
    mount root
  assetClose font
