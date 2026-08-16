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

-- The SIDEBAR half of the presentation enum, in an AUX WINDOW so one
-- shared scene covers BOTH arms: the primary stays `bar`, and this
-- window opens from a handler only the desktop tail's click reaches —
-- the phone runners cut the tail, the click never fires, and
-- 'createWindow' never runs where the capability is absent. No
-- capability read needed: reachability is the gate.
libraryId, shelvesId, loansId :: Word64
libraryId = 1
shelvesId = 2
loansId = 3

main :: IO ()
main = kayaMain $ \app -> do
  visitTally <- newIORef (0 :: Int)
  _ <- buildTx app $ do
    -- One construct carries the window's attributes (the unification
    -- rule). The hint is ADVISORY: `bar` is each desktop's horizontal
    -- spelling and the phones' physics regardless — no observable
    -- rides on it.
    window 0 [WTitle "sections", WSectionsPresentation 1]
    visits <- signal (VStr "archive: 0 visits")
    -- THE SEMANTIC ICON (docs/styling-plan.md D6): a tab bar without
    -- icons is not the platform's real thing, and the glyph that means
    -- `home` differs per platform — SF Symbols spells it `house`, and no
    -- shared asset would be legal anyway (SF Symbols are licensed to
    -- Apple platforms only).
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
            -- Programmatic selection: configuration, no echo —
            -- 'SOnSelected' must NOT fire (the scene asserts the
            -- count holds).
            buildTx app (selectSection archiveId), -- button#0
          buttonOn "open library" $ -- button#1
            -- The window's attributes ride its 'createWindow' exactly
            -- as the primary's ride 'window'; the sections carry no
            -- 'SOnSelected', since the tail reads the presentation the
            -- render body stamped and never switches them.
            buildTx app $ do
              createWindow libraryId [WTitle "library", WSectionsPresentation 2]
              -- The SIDEBAR arm carries symbols too: the source list is
              -- where a mac app most wants them.
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
