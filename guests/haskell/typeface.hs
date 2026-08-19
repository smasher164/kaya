{- The typeface conformance scene from Haskell: the brand typeface swaps
   the FAMILY and leaves the platform's ramp alone. The scene requests
   the VENDORED font's bytes so the resolved family is one string on
   every lane; guests/rust/typeface.rs carries the canonical note, and
   the byte-frozen contract is tools/scenes/typeface.steps. -}

import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ""
  -- Opened out here rather than below: Build is a pure state monad, so
  -- the one IO the brand call needs happens before the transaction
  -- opens.
  --
  -- ONE CALL, AND NO FILE I/O IN THE GUEST. The path, the environment
  -- override and the sentence for a miss were all hand-written here (and
  -- in seven sibling scenes) until asset arrived; they live in the core
  -- now (crates/kaya/src/assets.rs), which is also why the bytes never
  -- enter this guest's heap — the handle goes straight to the blob
  -- channel.
  font <- asset "fonts/sora-wght.ttf"
  buildTx app $ do
    -- BEFORE THE FIRST MOUNT, per the set-once wall: brand is identity,
    -- not state.
    brandTypeface "Sora" [TFontAsset font]
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
  -- The close is explicit and the redemption has already happened:
  -- buildTx ran the transaction's IO, so brandTypeface registered the
  -- bytes into the pending blob table, which keeps its own reference.
  assetClose font
