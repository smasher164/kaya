-- The sections conformance scene, Haskell port: two peer roots in
-- the primary window's section set — presentation context, not
-- lifecycle. The archive pane folds 'SOnSelected' into a visit
-- count, pinning the echo doctrine from both sides: the user's
-- switch emits (the harness drives the real switcher), while the
-- feed button's programmatic 'selectSection' moves the selection
-- silently. The count surviving switch round trips proves retention.
-- See guests/rust/sections.rs and tools/scenes/sections.steps.

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Word (Word64)
import KayaApp
import KayaWire (Value (..))

feedId, archiveId :: Word64
feedId = 7
archiveId = 8

main :: IO ()
main = kayaMain $ \app -> do
  visitTally <- newIORef (0 :: Int)
  _ <- buildTx app $ do
    windowTitle "sections"
    -- The ADVISORY hint, exercised on the wire: `bar` is each
    -- desktop's horizontal spelling and the phones' physics
    -- regardless — no observable rides on it.
    sectionsPresentation 1
    visits <- signal (VStr "archive: 0 visits")
    addSection feedId [STitle "Feed"]
    addSection
      archiveId
      [ STitle "Archive",
        SOnSelected
          ( do
              modifyIORef' visitTally (+ 1)
              n <- readIORef visitTally
              buildTx app $
                writeSignal visits (VStr ("archive: " ++ show n ++ " visits"))
          )
      ]
    feedRoot <-
      column
        []
        [ do
            ready <- signal (VStr "feed ready")
            labelBound ready, -- label#0
          buttonOn "to archive" $
            -- Programmatic selection: configuration, no echo —
            -- 'SOnSelected' must NOT fire (the scene asserts the
            -- count holds).
            buildTx app (selectSection archiveId) -- button#0
        ]
    mountIn feedId feedRoot
    archiveRoot <- column [] [labelBound visits] -- label#1
    mountIn archiveId archiveRoot
  return ()
