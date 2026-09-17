{-# LANGUAGE OverloadedStrings #-}

-- The a11yrows scene, Haskell port — guests/rust/a11yrows.rs,
-- tools/scenes/a11yrows.steps.

import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    notes <- collection

    -- Element-sourced: `expect_ax` refuses an ambiguous authored identifier,
    -- and a scalar row has one field to spend on an id (docs/deferred.md).
    heads <- collection

    root <-
      column
        [ each notes $
            withTplAttrs [TplA11yId element, TplA11yLabel element] entry,
          -- The template zone is located by the RESULT TYPE 'Tpl Node', and
          -- 'withTplAttrs' is the only way to reach a node.
          each heads $
            withTplAttrs [TplInset 8] $
              rowOf [withTplAttrs [TplRole Heading, TplA11yId element] (label element)]
        ]
    mount root

    -- The keys are the app's own: a scalar collection has no minter here.
    insert notes (T.pack "a") (T.pack "First note")
    insert notes (T.pack "b") (T.pack "Second note")
    insert heads (T.pack "h1") (T.pack "Heading one")
    insert heads (T.pack "h2") (T.pack "Heading two")
