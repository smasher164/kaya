{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The feed scene, Haskell port — guests/rust/feed.rs, tools/scenes/feed.steps.

import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Note = Note {text :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

data Todo = Todo {title :: Text, done :: Bool}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

data Post = PNote Note | PTodo Todo
  deriving stock (Generic)
  deriving anyclass (KayaSum)




main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    feed <- sumCollectionOf @Post
    doneCount <-
      sumDerive feed $ \entries ->
        let n = length [() | (_, PTodo (Todo _ True)) <- entries]
         in tshow n <> " done"

    let onPromote = submitTx app $ do
          entries <- sumItems feed
          case [(k, note) | (k, PNote note) <- entries] of
            (key, Note t) : _ -> sumUpdate feed key (PTodo (Todo t True))
            [] -> pure ()
        onToggle (key : _) checked = submitTx app $ do
          -- The case is the refinement, and the generated patch witnesses it:
          -- a stale occurrence lands in the other arm.
          entry <- sumGet feed key
          case entry of
            Just p@(PTodo _) ->
              sumPatch feed key p [set (field @"done" @Todo) checked]
            _ -> pure ()
        onToggle [] _ = error "kaya: onToggle's key path is never empty"

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
    sumInsert feed "a" (PNote (Note "jot one"))
    sumInsert feed "b" (PTodo (Todo "buy milk" False))
    sumInsert feed "c" (PNote (Note "jot two"))
