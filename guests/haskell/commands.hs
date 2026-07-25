{-# LANGUAGE DataKinds #-}

{- The standard-commands scene, Haskell port: a chord on every leaf kind
   (a checkable command, one option of a group, a plain command), the
   punctuation keys those chords need, and the `settings` role — which
   macOS shows in the application menu while the item stays addressable
   where it was declared. Canonical semantics in
   guests/rust/commands.rs; the byte-frozen contract in
   tools/scenes/commands.steps. -}

import Data.IORef (modifyIORef', newIORef, readIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  -- The settings command fires twice on purpose (once by the chord,
  -- once at its declared path), so its count lives outside the build.
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
          [ -- The settings command declares its own punctuation chord
            -- and the role that tells macOS where users look for it. An
            -- ordinary command sits beside it so the menu that declared
            -- it is not left empty once the platform moves it.
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
            -- A checkable command carrying its own key, and a group
            -- whose options each answer their own chord. Option order IS
            -- the index vocabulary: Name = 0, Date = 1.
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
