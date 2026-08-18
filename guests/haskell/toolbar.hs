{- The toolbar conformance scene, Haskell port: the `primary` bit as real
   window chrome (docs/chrome-plan.md C2). The app declares ONE catalog
   and marks two actions primary; every host promotes the same first two
   in catalog preorder. Canonical semantics in guests/rust/toolbar.rs;
   the byte-frozen contract in tools/scenes/toolbar.steps. -}

import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  saveEnabledRef <- newIORef True

  buildTx app $ do
    status <- signal (VStr "ready")
    -- Written against the MENU ITEM, never against any button: the
    -- promoted button IS that item, so it follows or the lowering kept
    -- a copy.
    canSave <- signal (VBool True)

    -- CATALOG PREORDER DECIDES PROMOTION — top-level groupings in
    -- menubar-append order, then each node's children in append order,
    -- depth-first. Save is the first primary and Find the second.
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
                  -- save-specific glyph (docs/styling-plan.md D6).
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
                -- Everything from here down is catalog, not chrome, on
                -- every platform.
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
