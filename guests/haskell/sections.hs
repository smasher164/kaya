-- The sections scene, Haskell port — guests/rust/sections.rs,
-- tools/scenes/sections.steps.

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Word (Word64)
import KayaApp
import KayaWire (Value (..))

feedId, archiveId :: Word64
feedId = 7
archiveId = 8

-- The SIDEBAR half rides an AUX WINDOW opened only from the desktop tail's
-- click, so 'createWindow' never runs where the capability is absent.
libraryId, shelvesId, loansId :: Word64
libraryId = 1
shelvesId = 2
loansId = 3

main :: IO ()
main = kayaMain $ \app -> do
  visitTally <- newIORef (0 :: Int)
  _ <- buildTx app $ do
    window 0 [WTitle "sections", WSectionsPresentation 1]
    visits <- signal (VStr "archive: 0 visits")
    -- A symbol names a CONCEPT (docs/styling-plan.md D6).
    addSection feedId [STitle "Feed", SSymbol SymbolHome]
    addSection
      archiveId
      [ STitle "Archive",
        SSymbol SymbolStar,
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
            -- Programmatic selection does NOT echo: 'SOnSelected' must not fire.
            buildTx app (selectSection archiveId), -- button#0
          buttonOn "open library" $ -- button#1
            buildTx app $ do
              createWindow libraryId [WTitle "library", WSectionsPresentation 2]
              addSectionIn libraryId shelvesId [STitle "Shelves", SSymbol SymbolSearch]
              addSectionIn libraryId loansId [STitle "Loans", SSymbol SymbolLock]
              shelvesRoot <-
                column
                  []
                  [ do
                      ready <- signal (VStr "shelves ready")
                      labelBound ready -- label#2
                  ]
              mountIn shelvesId shelvesRoot
              loansRoot <-
                column
                  []
                  [ do
                      ready <- signal (VStr "loans ready")
                      labelBound ready -- label#3
                  ]
              mountIn loansId loansRoot
        ]
    mountIn feedId feedRoot
    archiveRoot <- column [] [labelBound visits] -- label#1
    mountIn archiveId archiveRoot
  return ()
