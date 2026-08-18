{- The typeface conformance scene from Haskell: the brand typeface swaps
   the FAMILY and leaves the platform's ramp alone. The scene requests
   the VENDORED font's bytes so the resolved family is one string on
   every lane; guests/rust/typeface.rs carries the canonical note, and
   the byte-frozen contract is tools/scenes/typeface.steps. -}

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ""
  -- Read out here rather than below: Build is a pure state monad, so the
  -- one IO the brand call needs happens before the transaction opens.
  fontPath <- fromMaybe "guests/assets/fonts/sora-wght.ttf" <$> lookupEnv "KAYA_FONT_FILE"
  loaded <- try (BS.readFile fontPath) :: IO (Either IOException BS.ByteString)
  font <- case loaded of
    Right bytes -> pure bytes
    Left err ->
      errorWithoutStackTrace $
        "kaya: the typeface scene needs the vendored font at "
          ++ fontPath
          ++ " (set KAYA_FONT_FILE or run from the repo root): "
          ++ show err
  buildTx app $ do
    -- BEFORE THE FIRST MOUNT, per the set-once wall: brand is identity,
    -- not state.
    brandTypeface "Sora" [TFont font]
    window 0 [WTitle "typeface", WSize 480 360]

    -- The signals come first so the click handler can close over
    -- `status`: Build is a pure state monad, and a handler riding a
    -- constructor sees only what is already bound.
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
          -- DIFFERENT routes: the field inherits the root font, the
          -- textarea names its own ramp rung.
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
