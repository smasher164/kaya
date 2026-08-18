{- The styling conformance scene from Haskell (docs/styling-plan.md,
   slice 1): the brand accent, the role tier and the window inset —
   one design, so one scene. See guests/rust/styling.rs for the full
   note; the byte-frozen contract is tools/scenes/styling.steps. -}

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> buildTx app $ do
  -- BEFORE THE FIRST MOUNT, per the set-once wall: brand is identity,
  -- not state.
  brandAccent 0x3584E4
  window 0 [WTitle "styling", WSize 480 360, WInset 0]

  -- The signals come first so the click handlers can close over
  -- `status`: Build is a pure state monad, and a handler riding a
  -- constructor sees only what is already bound.
  heading <- signal (VStr "Sections")
  status <- signal (VStr "ready")

  root <-
    column
      []
      [ -- expect_ax resolves a target through its AUTHORED id into the
        -- real tree, so everything the steps read back is identified.
        labelBound heading [Role Heading, A11yId "title"], -- label#0
        labelBound status, -- label#1
        buttonOn "Delete" -- button#0
          (submitTx app (writeSignal status (VStr "deleted")))
          [Role Destructive, A11yId "delete"],
        buttonOn "Save" -- button#1
          (submitTx app (writeSignal status (VStr "saved")))
          [Role Prominent, A11yId "save"]
      ]
  mount root
