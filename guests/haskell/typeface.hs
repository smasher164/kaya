-- The typeface scene, Haskell port — guests/rust/typeface.rs,
-- tools/scenes/typeface.steps.

import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ""
  -- Out here: Build is a pure state monad, so the one IO the brand call needs
  -- happens before the transaction opens.
  font <- asset "fonts/sora-wght.ttf"
  buildTx app $ do
    -- BEFORE THE FIRST MOUNT, per the set-once wall.
    brandTypeface "Sora" [TFontAsset font]
    window 0 [WTitle "typeface", WSize 480 360]

    heading <- signal (VStr "typeface")
    status <- signal (VStr "ready")

    root <-
      column
        []
        [ -- The heading's text style OVERRIDES the root font, so this is
          -- the label a root-only lowering leaves in the system face.
          labelBound heading [Role Heading, A11yId "title"], -- label#0
          labelBound status, -- label#1
          -- A field AND a textarea, because the swap reaches them by
          -- DIFFERENT routes.
          entryOn (writeIORef draftRef), -- entry#0
          textarea, -- textarea#0
          buttonOn -- button#0
            "Go"
            ( do
                draft <- readIORef draftRef
                submitTx app (writeSignal status (VStr ("clicked " ++ draft)))
            )
        ]
    mount root
  assetClose font
