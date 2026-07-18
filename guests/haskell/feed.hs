{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The feed scene from Haskell: sum-typed elements, end to end. The
   data declaration is the sum, in the sum-of-records shape — each
   constructor wraps one record type, so the constructors' schemas and
   field tokens are the records' own, and `deriving Generic` plus empty
   instances are the whole obligation. The template takes a product of
   arms (checked complete at declaration, and again by the scene), and
   handlers eliminate with case — the scrutinee they matched is the
   witness the patch carries, and the model refuses a drifted entry, so
   a stale occurrence folds into nothing.

   Build like milestone2.hs, then run with KAYA_SELFTEST=feed. -}

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
          -- The first note, promoted to a finished todo: the model is
          -- asked which entry is a Note, and the update's new
          -- constructor restamps that key's copy in place.
          entries <- sumItems feed
          case [(k, note) | (k, PNote note) <- entries] of
            (key, Note t) : _ -> sumUpdate feed key (PTodo (Todo t True))
            [] -> pure ()
        onToggle keys checked = submitTx app $ do
          -- The case is the refinement; the matched scrutinee is the
          -- witness the patch carries. A stale occurrence lands in the
          -- other arm.
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
                  row
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
