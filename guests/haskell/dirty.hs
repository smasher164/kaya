-- The dirty-state conformance scene, Haskell port — unsaved work as
-- window chrome (docs/dirty-plan.md). One boolean beside 'WTitle' and
-- 'WVetoClose': the app declares STATE and the backend spells its own
-- platform's affordance (the dot in the close button on macOS, a
-- leading `*` in the rendered caption on Windows, a bullet in the GTK
-- header bar, nothing on the phones, which have none). See
-- guests/rust/dirty.rs and tools/scenes/dirty.steps.
--
-- TWO DECLARATIONS, ON PURPOSE. The edit handler writes the document
-- AND says `WDirty True`; the save handler writes it back and says
-- `WDirty False`. kaya does not watch your signals and guess — "the
-- document has unsaved changes" is a statement only the app can make,
-- and the window construct is where it makes it. The title string is
-- untouched by either.
--
-- AND THE MARK ARMS NOTHING. The close attempt fires the veto class
-- this window already opted into, the app opens its own dialog, and
-- cancelling keeps the window with the mark still up. That flow is
-- composed out of 'WVetoClose' and 'showAlert', both of which predate
-- this prop — which is the whole reason `dirty` is presentation and
-- nothing else.

import KayaApp
import KayaWire (Value (..), alertChoiceCancel)

main :: IO ()
main = kayaMain $ \app -> buildTx app $ do
  -- THE SIGNALS COME FIRST so the window construct below can close
  -- over `status`: Build is a pure state monad, so a handler riding a
  -- construct can only see what is already bound (the panels.hs
  -- ordering, for the same reason).
  doc <- signal (VStr "notes")
  status <- signal (VStr "saved")

  -- `WDirty` is absent here on purpose: the default False is the
  -- scene's first assertion, and a window that starts marked would
  -- pass the rest of the script while meaning nothing.
  --
  -- The close handler rides the window construct (handlers scope to
  -- the thing that creates them), so it can only ever mean this
  -- surface's close was asked for — nothing app-global, no id to
  -- inspect. `dirty` and `veto_close` are orthogonal on every
  -- platform; this window takes both because it is an editor: it owns
  -- its close so it can ask.
  window
    0
    [ WTitle "dirty",
      WVetoClose True,
      WOnCloseRequested
        ( -- Nothing has closed: the veto class says so. An editor with
          -- unsaved work asks; a clean one would agree at once.
          submitTx app $
            showAlert
              [ ATitle "unsaved changes",
                AMessage "the document has unsaved changes",
                AAction "Discard",
                ACancel "Keep Editing"
              ]
              ( \choice ->
                  submitTx app $
                    if choice == alertChoiceCancel
                      then -- Answering a dialog is not saving, so this
                      -- writes the status and NOTHING else: the mark
                      -- stays up.
                        writeSignal status (VStr "kept editing")
                      else -- Agreeing destroys the surface, which for the
                      -- PRIMARY window is the process itself — so the
                      -- scene answers cancel and this arm stays the
                      -- honest spelling of "yes, close it" rather than
                      -- a step.
                        destroyWindow 0
              )
        )
    ]

  root <-
    column
      []
      [ labelBound doc, -- label#0
        labelBound status, -- label#1
        -- ONE TRANSACTION for all three writes: the document, the
        -- status and the declaration are one atomic edit, and pressing
        -- edit twice is not a different document.
        buttonOn "edit" -- button#0
          ( submitTx app $ do
              writeSignal doc (VStr "notes and a line")
              writeSignal status (VStr "unsaved")
              window 0 [WDirty True]
          ),
        buttonOn "save" -- button#1
          ( submitTx app $ do
              writeSignal status (VStr "saved")
              window 0 [WDirty False]
          )
      ]
  mount root
