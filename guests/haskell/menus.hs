{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- The menus scene, Haskell port — guests/rust/menus.rs,
-- tools/scenes/menus.steps.

import Data.IORef (newIORef, readIORef, writeIORef)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  -- Filled after the build: the Remove fold reads the collection back here.
  itemsRef <- newIORef (Nothing :: Maybe Collection)

  (groups, itemsColl) <- buildTx app $ do
    status <- signal (T.pack "ready")
    canExport <- signal False
    details <- signal False
    sort <- signal (0.0 :: Double)

    let onShare = submitTx app (writeSignal status (T.pack "shared"))

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
              IOnActivate (submitTx app (writeSignal status (T.pack "saved")))
            ],
          item "Export" [IEnabledBy canExport, ISymbol SymbolForward],
          pure share
        ]
    window
      primary
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
                              (T.pack (if on then "details on" else "details off"))
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
                          (T.pack (if index == 1 then "sorted date" else "sorted name"))
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
                    [groupV, itemKeyV] -> do
                      let group = fromWire groupV :: Text
                          itemKey = fromWire itemKeyV :: Text
                      maybeItems <- readIORef itemsRef
                      case maybeItems of
                        Just itemsColl ->
                          submitTx app $ do
                            remove (itemsColl `at` group) itemKey
                            writeSignal status
                              ("removed " <> group <> "/" <> itemKey)
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

    targetText <- signal (T.pack "rename target")

    root <-
      column
        [ labelBound status, -- label#0
          buttonOn "enable export" $ -- button#0
            submitTx app (writeSignal canExport True),
          buttonOn "reset menu state" $ -- button#1
            submitTx app $ do
              writeSignal details False
              writeSignal sort (0.0 :: Double)
              writeSignal status (T.pack "ready"),
          buttonOn "extend menus" $ -- button#2
            submitTx app $ do
              setMenuPrimary share False
              setMenuLabel file "Document"
              menuAppend
                file
                [item "Publish" [IPrimary True, ISymbol SymbolCopy, IOnActivate onShare]]
              window primary [WMenus [menu "Tools" [] [item "Inspect" [ISymbol SymbolSearch]]]],
          do
            target <- labelBound targetText -- label#1
            contextMenu
              target
              [ item
                  "Rename"
                  [ ISymbol SymbolEdit,
                    IOnActivate (submitTx app (writeSignal status (T.pack "renamed")))
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
    insert groups ("g2" :: Text) ("Home" :: Text)
    insert (itemsColl `at` ("g2" :: Text)) ("a" :: Text) ("water plants" :: Text)
