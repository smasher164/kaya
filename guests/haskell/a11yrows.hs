{- The stamped-accessibility scene from Haskell: two entries stamped
   from ONE template, each carrying its OWN ROW's accessibility
   identity, and a second collection whose stamped row INSETS its
   children and whose stamped label says it is a HEADING.

   A SCENE OF ITS OWN because this binding creates a container AFTER
   its children (guests/haskell/reorder.hs writes the rule down), so a
   For added to the a11y scene would make column#0 name a different
   widget here than in Rust.

   Canonical semantics in guests/rust/a11yrows.rs; the byte-frozen
   contract in tools/scenes/a11yrows.steps. -}

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    notes <- collection

    -- Both props ELEMENT-SOURCED, and the id is forced: `expect_ax`
    -- addresses the real tree by the authored identifier and refuses an
    -- ambiguous one (docs/deferred.md, the template role/inset entry).
    --
    -- A scalar row has exactly one field to spend on an id, so the
    -- stamped styling props need a collection of their own. Both of
    -- THOSE are const: facts about the PROTOTYPE.
    heads <- collection

    root <-
      column
        [ each notes $
            withTplAttrs [TplA11yId element, TplA11yLabel element] entry,
          -- One surface: the template zone is located by the RESULT TYPE
          -- 'Tpl Node', and 'withTplAttrs' is the only way to reach a
          -- node, so both props attach by nesting.
          each heads $
            withTplAttrs [TplInset 8] $
              rowOf [withTplAttrs [TplRole Heading, TplA11yId element] (label element)]
        ]
    mount root

    -- The keys are the app's own and arbitrary: a scalar collection has
    -- no minter in this binding ('insertFresh' is record-typed), and
    -- what identifies these rows to the accessibility tree is their text.
    insert notes (VStr "a") (VStr "First note")
    insert notes (VStr "b") (VStr "Second note")
    insert heads (VStr "h1") (VStr "Heading one")
    insert heads (VStr "h2") (VStr "Heading two")
