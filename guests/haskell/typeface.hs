{- The typeface conformance scene from Haskell (docs/styling-plan.md
   Slice 2b): the brand typeface swaps the FAMILY and leaves the
   platform's ramp alone. See guests/rust/typeface.rs for the full note;
   the byte-frozen contract is tools/scenes/typeface.steps.

   What this port shows of the Haskell surface:
     - `brandTypeface "Sora" [...]` — one name, both arities, and the
       attribute list is where the font bytes and the per-platform rows
       ride. The bare `brandTypeface "Sora"` is the whole call for an app
       whose one family name is right everywhere. It names no size
       anywhere, because sizes, weights and metrics stay the platform's;
       `Role Heading` below is what carries emphasis, and that is exactly
       what makes a family swap safe.
     - `TFont bytes` — the blob form. WHY A BUNDLED FONT, and why no
       `TFor` row: the reasoning is in guests/rust/typeface.rs's doc
       comment, which is the canonical note for this scene. In short, the
       scene requests the VENDORED font's bytes so the resolved family is
       one string on every lane and no platform's fallback can equal it.
       `TFor` in that same list is what a name-based app would reach for
       instead: a row travels UNRESOLVED to every backend and each one
       picks its own, which is why no guest ever asks which platform it
       is running on.

   Everything after the brand call is ordinary widgets, which is the
   claim the scene makes: a typeface is chrome, so the field still takes
   text and the button still fires. -}

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  -- The fold: widget-owned state arrives as occurrences, and the app's
  -- copy is this IORef rather than a widget read.
  draftRef <- newIORef ""
  -- THE VENDORED BYTES, read out here rather than below: Build is a pure
  -- state monad, so the one IO the brand call needs happens before the
  -- transaction opens.
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
    -- not state, and a backend never sees a typeface it would have to
    -- un-apply.
    --
    -- The blob registers with the platform's app-font machinery and the
    -- "Sora" request resolves to it — register-then-resolve, the same
    -- call a brand book's licensed font would make.
    brandTypeface "Sora" [TFont font]
    window 0 [WTitle "typeface", WSize 480 360]

    -- The signals come first so the click handler below can close over
    -- `status` (Build is a pure state monad — a handler riding a
    -- constructor sees only what is already bound).
    heading <- signal (VStr "typeface")
    status <- signal (VStr "ready")

    root <-
      column
        []
        [ -- The heading's text style OVERRIDES the root font, so this
          -- label is the one a root-only lowering leaves in the system
          -- face. expect_ax resolves it through its authored id, the
          -- a11y scene's discipline.
          labelBound heading [Role Heading, A11yId "title"], -- label#0
          labelBound status, -- label#1
          -- A FIELD AND A TEXTAREA, because they are the two views the
          -- observation reads (NSTextField and NSTextView on this
          -- platform) and they arrive by DIFFERENT routes: the field
          -- inherits the root font, the textarea names its own ramp rung
          -- and takes the swap explicitly. A scene with one of them
          -- could not tell a half-applied lowering from a whole one.
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
