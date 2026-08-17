{- The toolbar conformance scene, Haskell port: the `primary` bit as real
   window chrome (docs/chrome-plan.md C2). The app declares ONE catalog
   and marks two actions primary; every host promotes the same first two
   in catalog preorder — the desktop's toolbar, the phones' top bar —
   and the rest of the catalog stays reachable where that host keeps it.

   There is no toolbar vocabulary to spell here, and that is the point:
   this guest is the menus guest with a promotion bit and no new call.
   Canonical semantics in guests/rust/toolbar.rs; the byte-frozen
   contract in tools/scenes/toolbar.steps. -}

import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  -- The guest's own copy of the enablement, flipped by the button. The
  -- signal is the model; this IORef is only what "the other one" means.
  saveEnabledRef <- newIORef True

  buildTx app $ do
    status <- signal (VStr "ready")
    -- The one signal the enablement round-trip turns on. The app writes
    -- it against the MENU ITEM and says nothing about any button: the
    -- promoted button is that same item, so it follows or the lowering
    -- kept a copy.
    canSave <- signal (VBool True)

    -- CATALOG PREORDER DECIDES PROMOTION — top-level groupings in
    -- menubar-append order, then each node's children in append order,
    -- depth-first. Save is the first primary and Find the second, so
    -- every host's promoted set is [Save, Find] however large its own k
    -- is.
    window
      0
      [ WTitle "toolbar",
        WMenus
          [ menu
              "File"
              []
              [ item
                  "Save"
                  -- `done` is the checkmark idiom: the vocabulary has no
                  -- save-specific glyph, and neither does Apple's own
                  -- catalog (docs/styling-plan.md D6).
                  [ ISymbol SymbolDone,
                    IPrimary True,
                    IEnabledBy canSave,
                    IShortcut "primary+s",
                    IOnActivate (submitTx app (writeSignal status (VStr "saved")))
                  ],
                item
                  "Export"
                  [ ISymbol SymbolForward,
                    IOnActivate (submitTx app (writeSignal status (VStr "exported")))
                  ]
              ],
            menu
              "Edit"
              []
              [ item
                  "Find"
                  [ ISymbol SymbolSearch,
                    IPrimary True,
                    IOnActivate (submitTx app (writeSignal status (VStr "found")))
                  ],
                -- The remainder: everything below is catalog, not
                -- chrome, on every platform — which is what makes the
                -- bare expect_toolbar's second half a real question.
                item "Replace" [ISymbol SymbolEdit]
              ],
            menu
              "View"
              []
              [ item "Refresh" [ISymbol SymbolRefresh],
                item "Info" [ISymbol SymbolInfo]
              ]
          ]
      ]

    root <-
      column
        [ labelBound status, -- label#0
          buttonOn "toggle save" $ do
            -- button#0
            saveEnabled <- not <$> readIORef saveEnabledRef
            writeIORef saveEnabledRef saveEnabled
            submitTx app (writeSignal canSave (VBool saveEnabled))
        ]
    mount root
