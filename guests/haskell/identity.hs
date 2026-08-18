{- The app-identity conformance scene from Haskell: an app declares what
   it is called and what it looks like, and the platform shows both.
   Canonical semantics in guests/rust/identity.rs; the byte-frozen
   contract in tools/scenes/identity.steps.

   THE MARK IS THE VENDORED ONE (guests/assets/icons/kaya-mark.png, four
   flat quadrants) because no platform's own default icon can land on
   four declared colours, so a lowering that never applied can never read
   as a pass. KAYA_ICON_FILE is how a runner that cannot see the repo
   points at a pushed copy.

   THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is the
   blank an app's NAME fills on every platform. -}

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ""
  -- Read out here rather than below: Build is a pure state monad, so the
  -- one IO the declaration needs happens before the transaction opens.
  iconPath <- fromMaybe "guests/assets/icons/kaya-mark.png" <$> lookupEnv "KAYA_ICON_FILE"
  loaded <- try (BS.readFile iconPath) :: IO (Either IOException BS.ByteString)
  icon <- case loaded of
    Right bytes -> pure bytes
    Left err ->
      errorWithoutStackTrace $
        "kaya: the identity scene needs the vendored mark at "
          ++ iconPath
          ++ " (set KAYA_ICON_FILE or run from the repo root): "
          ++ show err
  buildTx app $ do
    -- BEFORE THE FIRST MOUNT, per the declared-once wall.
    appIdentity "Aurora Notes" icon
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
    createWindow 1 [WSize 360 240]
    caption <- signal (VStr "no title of its own")
    aux <- column [] [labelBound caption] -- label#2
    mountIn 1 aux
