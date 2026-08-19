{- The app-identity conformance scene from Haskell: an app declares what
   it is called and what it looks like, and the platform shows both.
   Canonical semantics in guests/rust/identity.rs; the byte-frozen
   contract in tools/scenes/identity.steps.

   THE MARK IS THE VENDORED ONE (four flat quadrants) because no
   platform's own default icon can land on four declared colours, so a
   lowering that never applied can never read as a pass.

   THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is the
   blank an app's NAME fills on every platform. -}

import Control.Monad (when)
import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ""
  -- Opened out here rather than below: Build is a pure state monad, so
  -- the one IO the declaration needs happens before the transaction
  -- opens. The bytes never enter this guest's heap — the handle goes
  -- straight to the blob channel.
  icon <- asset "icons/kaya-mark.png"
  -- Opened out here for the same reason the asset is: Build is a pure
  -- state monad and this is IO. See the untitled window below for why
  -- the scene asks at all.
  caps <- capabilities
  buildTx app $ do
    -- BEFORE THE FIRST MOUNT, per the declared-once wall.
    appIdentityAsset "Aurora Notes" icon
    -- ONE PROMOTED COMMAND, AND IT IS NOT ABOUT COMMANDS. Windows mints
    -- its custom caption from the first promotion and from nothing else,
    -- and a custom caption REPLACES the system one — taking the
    -- system-drawn app icon with it. That is why the identity has a
    -- second Windows sink at all, and a scene with no promotion anywhere
    -- would leave that sink's arm unreached.
    window
      0
      [ WTitle "identity",
        WSize 480 360,
        WMenus [menu "File" [] [item "Save" [ISymbol SymbolDone, IPrimary True]]]
      ]

    -- The signals come first so the click handler can close over
    -- `status`: Build is a pure state monad, and a handler riding a
    -- constructor sees only what is already bound.
    heading <- signal (VStr "identity")
    status <- signal (VStr "ready")

    root <-
      column
        []
        [ labelBound heading, -- label#0
          labelBound status, -- label#1
          entryOn (writeIORef draftRef), -- entry#0
          buttonOn -- button#0
            "Go"
            ( do
                draft <- readIORef draftRef
                submitTx app (writeSignal status (VStr ("clicked " ++ draft)))
            )
        ]
    mount root

    -- THE UNTITLED WINDOW. It declares no title at all rather than an
    -- empty one: an empty string is a title an app WROTE, and the rule
    -- under test is what a window with nothing written shows.
    --
    -- THE HOST IS ASKED, in all eight ports of this scene, even where
    -- the answer is never no: the eight ports are one scene, and a
    -- binding surface no guest calls is one no lane exercises.
    when (auxWindows caps) $ do
      createWindow 1 [WSize 360 240]
      caption <- signal (VStr "no title of its own")
      aux <- column [] [labelBound caption] -- label#2
      mountIn 1 aux
  assetClose icon
