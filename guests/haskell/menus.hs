{-# LANGUAGE DataKinds #-}

{- The menus conformance scene, Haskell port: the command vocabulary (a
   File/View/Sort menu bar, context menus on a live label and on stamped
   rows), the uncontrolled-menu echo doctrine, and a late
   rename/append/promotion rework. Canonical semantics in
   guests/rust/menus.rs; the byte-frozen contract in tools/scenes/menus.steps. -}

import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..), kindLabel)

main :: IO ()
main = kayaMain $ \app -> do
  -- The per-group items collection escapes the build as its result; the
  -- Remove fold reads it back through this IORef, filled right after the
  -- build and before dispatch starts.
  itemsRef <- newIORef (Nothing :: Maybe Collection)

  (groups, itemsColl) <- buildTx app $ do
    status <- signal (VStr "ready")
    canExport <- signal (VBool False)
    details <- signal (VBool False)
    sort <- signal (VF64 0.0)

    let onShare = submitTx app (writeSignal status (VStr "shared"))

    -- File and its Export leaf share one enablement signal: one write
    -- moves both. File and Share realize early because the extend handler
    -- needs their handles; 'pure' slots them back in.
    share <- item "Share" [IPrimary True, IOnActivate onShare]
    file <-
      menu
        "File"
        [IEnabledBy canExport]
        [ item
            "Save"
            [ IShortcut "primary+s",
              IOnActivate (submitTx app (writeSignal status (VStr "saved")))
            ],
          item "Export" [IEnabledBy canExport],
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
    -- Catalog built live: items are shared across stamped copies; the
    -- template only attaches, and each activation carries its key path.
    catalog <-
      contextCatalog
        [ item
            "Remove"
            [ IOnActivateNode
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

    -- The group For escapes its items collection; 'pure groupList' slots
    -- the live For into the root below. Remove's activation names BOTH
    -- keys (group, then item).
    (groupList, itemsColl) <- forEach groups $ do
      itemsColl <- collection
      itemList <- each itemsColl $ do
        -- label#2 once g2/a stamps. `element` is the scalar
        -- collection's own token — its element IS the value, so there
        -- is no field name to give — and it lowers to the same
        -- bind_element this line used to spell at the widget-kind floor.
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
            -- The folds never echo the user's pick, so details/sort still
            -- hold False/0; these two prop writes are real checked/value
            -- records (never coalesced) that reset the user-state mirror.
            submitTx app $ do
              writeSignal details (VBool False)
              writeSignal sort (VF64 0.0)
              writeSignal status (VStr "ready"),
          buttonOn "extend menus" $ -- button#2
            -- Append-only: rename the retained File, move the promotion
            -- hint from Share to Publish, grow the bar by Tools.
            submitTx app $ do
              setMenuPrimary share False
              setMenuLabel file "Document"
              menuAppend
                file
                [item "Publish" [IPrimary True, IOnActivate onShare]]
              window 0 [WMenus [menu "Tools" [] [item "Inspect" []]]],
          do
            target <- labelBound targetText -- label#1
            contextMenu
              target
              [ item
                  "Rename"
                  [IOnActivate (submitTx app (writeSignal status (VStr "renamed")))]
              ]
            return target,
          pure groupList
        ]
    mount root
    return (groups, itemsColl)

  writeIORef itemsRef (Just itemsColl)

  -- Seed after mount: the stamp path attaches the shared catalog and keys.
  buildTx app $ do
    insert groups (VStr "g2") (VStr "Home")
    insert (itemsColl `at` VStr "g2") (VStr "a") (VStr "water plants")
