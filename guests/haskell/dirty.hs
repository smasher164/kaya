{-# LANGUAGE OverloadedStrings #-}

-- The dirty scene, Haskell port — guests/rust/dirty.rs,
-- tools/scenes/dirty.steps.

import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> buildTx app $ do
  -- The signals come first: Build is a pure state monad, so a handler riding
  -- a construct can only see what is already bound.
  doc <- signal (T.pack "notes")
  status <- signal (T.pack "saved")

  -- `WDirty` is absent on purpose: the default False is the first assertion.
  window
    primary
    [ WTitle "dirty",
      WVetoClose True,
      WOnCloseRequested
        (
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
                      then -- Answering a dialog is not saving: the mark
                      -- stays up.
                        writeSignal status (T.pack "kept editing")
                      else -- This call ABORTS if it ever runs, so the
                      -- scene answers cancel (docs/traps.md, "An app can
                      -- VETO a close but cannot AGREE to one").
                        destroyWindow 0
              )
        )
    ]

  root <-
    column
      []
      [ labelBound doc, -- label#0
        labelBound status, -- label#1
        buttonOn "edit" -- button#0
          ( submitTx app $ do
              writeSignal doc (T.pack "notes and a line")
              writeSignal status (T.pack "unsaved")
              window primary [WDirty True]
          ),
        buttonOn "save" -- button#1
          ( submitTx app $ do
              writeSignal status (T.pack "saved")
              window primary [WDirty False]
          )
      ]
  mount root
