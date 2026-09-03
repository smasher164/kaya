{-# LANGUAGE DataKinds #-}

-- The commands scene, Haskell port — guests/rust/commands.rs,
-- tools/scenes/commands.steps.

import Data.IORef (modifyIORef', newIORef, readIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  settingsRef <- newIORef (0 :: Int)

  buildTx app $ do
    status <- signal (VStr "ready")
    details <- signal (VBool False)
    sort <- signal (VF64 0.0)

    let onSettings = do
          modifyIORef' settingsRef (+ 1)
          n <- readIORef settingsRef
          submitTx app (writeSignal status (VStr ("settings " ++ show n)))

    window
      0
      [ WTitle "commands",
        WMenus
          [ -- Reload sits beside Settings so this menu is not left empty
            -- once the platform moves the settings item elsewhere.
            menu
              "File"
              []
              [ item "Reload" [],
                item
                  "Settings…"
                  [ IShortcut "primary+comma",
                    IRole roleSettings,
                    IOnActivate onSettings
                  ]
              ],
            -- Option order IS the index vocabulary: Name = 0, Date = 1.
            menu
              "View"
              []
              [ toggle
                  "Details"
                  [ ICheckedBy details,
                    IShortcut "primary+backslash",
                    IOnToggle
                      ( \on ->
                          submitTx app $
                            writeSignal status
                              (VStr (if on then "details on" else "details off"))
                      )
                  ],
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
                  [ option "Name" [IShortcut "primary+1"],
                    option "Date" [IShortcut "primary+2"]
                  ]
              ]
          ]
      ]

    root <- column [] [labelBound status] -- label#0
    mount root
