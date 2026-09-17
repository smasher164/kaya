{-# LANGUAGE OverloadedStrings #-}

-- The toolbar scene, Haskell port — guests/rust/toolbar.rs,
-- tools/scenes/toolbar.steps.

import Data.IORef (newIORef, readIORef, writeIORef)

import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  saveEnabledRef <- newIORef True

  buildTx app $ do
    status <- signal (T.pack "ready")
    -- Written against the MENU ITEM: the promoted button IS that item.
    canSave <- signal (True)

    -- CATALOG PREORDER DECIDES PROMOTION — menubar-append order, then
    -- children depth-first, so every host promotes [Save, Find].
    window
      primary
      [ WTitle "toolbar",
        WMenus
          [ menu
              "File"
              []
              [ item
                  "Save"
                  -- No save-specific glyph; `done` is the checkmark idiom
                  -- (docs/styling-plan.md D6).
                  [ ISymbol SymbolDone,
                    IPrimary True,
                    IEnabledBy canSave,
                    IShortcut "primary+s",
                    IOnActivate (submitTx app (writeSignal status (T.pack "saved")))
                  ],
                item
                  "Export"
                  [ ISymbol SymbolForward,
                    IOnActivate (submitTx app (writeSignal status (T.pack "exported")))
                  ]
              ],
            menu
              "Edit"
              []
              [ item
                  "Find"
                  [ ISymbol SymbolSearch,
                    IPrimary True,
                    IOnActivate (submitTx app (writeSignal status (T.pack "found")))
                  ],
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
            submitTx app (writeSignal canSave (saveEnabled))
        ]
    mount root
