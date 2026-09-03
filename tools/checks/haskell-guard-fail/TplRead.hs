-- MUST NOT COMPILE — the fixture is compiled expecting FAILURE.
-- The record-time mirror-read guard, Haskell arm: the wall here is the
-- type system (reads are Build-typed, a template body is Tpl-typed, and
-- Tpl has no lift from Build). If this compiles, that wall has fallen and
-- the binding needs the runtime guard the others carry.
module TplRead where

import KayaApp

badScene :: Build ()
badScene = do
  c <- collection
  _ <- forEach c $ do
    _ <- items c -- the read: a Build action inside a Tpl do-block
    pure ()
  pure ()
