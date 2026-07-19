-- MUST NOT COMPILE.
--
-- The record-time mirror-read guard, Haskell arm. A template body (a
-- For or When blueprint) is recorded once and replayed by the core —
-- a collection-model read inside one would bake this moment's data
-- into every future stamp, silently dead. The other bindings guard
-- this at run time (Python's _guard_mirror_read, Swift's
-- preconditionFailure, OCaml's failwith); here the guard is the type
-- system itself: every read (items, count, recordItems, sumItems,
-- sumGet) is Build-typed, a template body is Tpl-typed, and Tpl has
-- no reads and no lift from Build — so the read below is a type
-- error ("Couldn't match ... Build ... with ... Tpl ...").
--
-- This fixture pins that wall: it is compiled expecting FAILURE. If
-- it ever compiles, the Build/Tpl monad wall has fallen and the
-- Haskell binding needs the runtime guard the other bindings carry.
module TplRead where

import KayaApp

badScene :: Build ()
badScene = do
  c <- collection
  _ <- forEach c $ do
    _ <- items c -- the read: a Build action inside a Tpl do-block
    pure ()
  pure ()
