{-# LANGUAGE DataKinds #-}

-- The menus scene, Haskell port — guests/rust/menus.rs,
-- tools/scenes/menus.steps.

import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..), kindLabel)

main :: IO ()
main = kayaMain $ \app -> do
  -- Filled after the build: the Remove fold reads the collection back here.
  itemsRef <- newIORef (Nothing :: Maybe Collection)

  (groups, itemsColl) <- buildTx app $ do
    status <- signal (VStr "ready")
    canExport <- signal (VBool False)
    details <- signal (VBool False)
    sort <- signal (VF64 0.0)

    let onShare = submitTx app (writeSignal status (VStr "shared"))

    -- File and Share realize early because the extend handler needs their
    -- handles; 'pure' slots them back in.
    share <- item "Share" [IPrimary True, IOnActivate onShare]
    file <-
      menu
        "File"
        [IEnabledBy canExport]
        [ item
            "Save"
            -- No `save` in the symbol vocabulary; `done` is the checkmark
            -- idiom (docs/styling-plan.md D6).
            [ ISymbol SymbolDone,
              IShortcut "primary+s",
              IOnActivate (submitTx app (writeSignal status (VStr "saved")))
            ],
          item "Export" [IEnabledBy canExport, ISymbol SymbolForward],
          pure share
        ]
    window
      0
      [ WTitle "menus",
        WMenus
          [ pure file,
            menu
              "View"
              []
              [ toggle
                  "Details"
                  [ ICheckedBy details,
                    ISymbol SymbolInfo,
                    IOnToggle
                      ( \on ->
                          submitTx app $
                            writeSignal status
                              (VStr (if on then "details on" else "details off"))
                      )
                  ]
              ],
            -- Option order IS the index vocabulary: Name = 0, Date = 1.
            radioGroup
              "Sort"
              [ IValueBy sort,
                IOnSelect
                  ( \index ->
                      submitTx app $
                        writeSignal status
                          (VStr (if index == 1 then "sorted date" else "sorted name"))
                  )
              ]
              [option "Name" [], option "Date" []]
          ]
      ]

    groups <- collection
    -- Built live: the items are SHARED across stamped copies.
    catalog <-
      contextCatalog
        [ item
            "Remove"
            [ ISymbol SymbolDelete,
              IOnActivateNode
                ( \keys -> case keys of
                    [VStr group, VStr itemKey] -> do
                      maybeItems <- readIORef itemsRef
                      case maybeItems of
                        Just itemsColl ->
                          submitTx app $ do
                            remove (itemsColl `at` VStr group) (VStr itemKey)
                            writeSignal status
                              (VStr ("removed " ++ group ++ "/" ++ itemKey))
                        Nothing -> return ()
                    _ -> return ()
                )
            ]
        ]

    (groupList, itemsColl) <- forEach groups $ do
      itemsColl <- collection
      itemList <- each itemsColl $ do
        -- label#2 once g2/a stamps.
        row <- label element
        nodeContextMenu row catalog
      _ <- columnOf [pure itemList]
      return itemsColl

    targetText <- signal (VStr "rename target")

    root <-
      column
        [ labelBound status, -- label#0
          buttonOn "enable export" $ -- button#0
            submitTx app (writeSignal canExport (VBool True)),
          buttonOn "reset menu state" $ -- button#1
            submitTx app $ do
              writeSignal details (VBool False)
              writeSignal sort (VF64 0.0)
              writeSignal status (VStr "ready"),
          buttonOn "extend menus" $ -- button#2
            submitTx app $ do
              setMenuPrimary share False
              setMenuLabel file "Document"
              menuAppend
                file
                [item "Publish" [IPrimary True, ISymbol SymbolCopy, IOnActivate onShare]]
              window 0 [WMenus [menu "Tools" [] [item "Inspect" [ISymbol SymbolSearch]]]],
          do
            target <- labelBound targetText -- label#1
            contextMenu
              target
              [ item
                  "Rename"
                  [ ISymbol SymbolEdit,
                    IOnActivate (submitTx app (writeSignal status (VStr "renamed")))
                  ]
              ]
            return target,
          pure groupList
        ]
    mount root
    return (groups, itemsColl)

  writeIORef itemsRef (Just itemsColl)

  -- Seeded after the mount, so the copy stamps from a closed template.
  buildTx app $ do
    insert groups (VStr "g2") (VStr "Home")
    insert (itemsColl `at` VStr "g2") (VStr "a") (VStr "water plants")
