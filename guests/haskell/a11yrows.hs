-- The a11yrows scene, Haskell port — guests/rust/a11yrows.rs,
-- tools/scenes/a11yrows.steps.

import KayaApp
import KayaWire (Value (..))

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
    insert notes (VStr "a") (VStr "First note")
    insert notes (VStr "b") (VStr "Second note")
    insert heads (VStr "h1") (VStr "Heading one")
    insert heads (VStr "h2") (VStr "Heading two")
