{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The feed scene, Haskell port — guests/rust/feed.rs, tools/scenes/feed.steps.

import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data Note = Note {text :: String} deriving (Generic)

data Todo = Todo {title :: String, done :: Bool} deriving (Generic)

data Post = PNote Note | PTodo Todo deriving (Generic)

instance KayaRecord Note

instance KayaRecord Todo

instance KayaSum Post

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    feed <- sumCollectionOf (Proxy :: Proxy Post)
    doneCount <-
      sumDerive feed $ \entries ->
        let n = length [() | (_, PTodo (Todo _ True)) <- entries]
         in VStr (show n ++ " done")

    let onPromote = submitTx app $ do
          entries <- sumItems feed
          case [(k, note) | (k, PNote note) <- entries] of
            (key, Note t) : _ -> sumUpdate feed key (PTodo (Todo t True))
            [] -> pure ()
        onToggle keys checked = submitTx app $ do
          -- The case is the refinement, and the generated patch witnesses it:
          -- a stale occurrence lands in the other arm.
          entry <- sumGet feed (head keys)
          case entry of
            Just p@(PTodo _) ->
              sumPatch feed (head keys) p [set (field @"done" @Todo) checked]
            _ -> pure ()

    root <-
      row
        [ buttonOn "promote" onPromote,
          labelBound doneCount,
          eachSum feed
            [ sumArm (PNote (Note "")) $ do
                _ <- label (field @"text" @Note)
                pure (),
              sumArm (PTodo (Todo "" False)) $ do
                _ <-
                  rowOf
                    [ checkbox (field @"done" @Todo) onToggle,
                      label (field @"title" @Todo)
                    ]
                pure ()
            ]
        ]
    mount root
    sumInsert feed (VStr "a") (PNote (Note "jot one"))
    sumInsert feed (VStr "b") (PTodo (Todo "buy milk" False))
    sumInsert feed (VStr "c") (PNote (Note "jot two"))
