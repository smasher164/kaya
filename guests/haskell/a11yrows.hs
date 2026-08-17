{- The stamped-accessibility scene from Haskell: two entries stamped
   from ONE template, each carrying its OWN ROW's accessibility
   identity, read back out of the platform's real tree — and, from a
   second collection, a stamped row that INSETS its children and a
   stamped label that says it is a HEADING.

   The a11y scene makes that claim for LIVE widgets; this one makes it
   for COPIES, which none of the accessibility milestone's 719 legs
   reached — until the template zone could spell the props, no guest
   could author a stamped widget's name at all. The spelling here is
   'withTplAttrs' over two 'TplAttr's, and both take 'element': a scalar
   collection carries one field and the element IS it, so each copy's
   spoken name is its own row's text.

   A SCENE OF ITS OWN, and the reason is scene shape rather than size.
   A For materializes as a real column, the harness registries are
   creation order, and this binding creates a container AFTER its
   children (guests/haskell/reorder.hs writes the rule down), so a For
   added to the a11y scene — which asserts every container kind
   ordinally — would make column#0 name a different widget here than in
   Rust. This scene asserts no container at all, so the For's column may
   land at either end of the registry and both targets below still mean
   the same widget everywhere.

   Canonical semantics in guests/rust/a11yrows.rs; the byte-frozen
   contract in tools/scenes/a11yrows.steps. -}

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    notes <- collection

    -- BOTH PROPS ELEMENT-SOURCED. The label is the point — a list row
    -- announcing its own name to assistive tech is what a sourced
    -- template label exists for. The id is forced: expect_ax resolves
    -- its target to the authored identifier and then searches the REAL
    -- tree by it, so copies sharing a const id are indistinguishable to
    -- that verb and the read refuses them with the count it measured. A
    -- shared const id stays legal — nothing in the core deduplicates —
    -- it is just not a thing this assertion can read back.
    --
    -- The field itself is uncontrolled and seeded from nothing
    -- ('entry', not 'entryBound'): the row reaches the copy's
    -- accessibility surface and nowhere else, which is exactly what the
    -- two assertions read.
    -- THE STAMPED STYLING PROPS, on a collection of their own rather
    -- than two more elements in the first. 'expect_ax' addresses the
    -- real tree BY the authored identifier and refuses an ambiguous
    -- one, and a scalar row has exactly one field to spend on an id —
    -- so a second readable stamped element needs its own strings.
    --
    -- BOTH CONST, unlike the pair above, and the reason is the one
    -- 'TplAccepts' gives: what a copy MEANS, and how far its prototype
    -- holds children off its edge, are facts about the PROTOTYPE. Every
    -- copy of one blueprint is a heading, and every copy insets by 8.
    heads <- collection

    root <-
      column
        [ each notes $
            withTplAttrs [TplA11yId element, TplA11yLabel element] entry,
          -- ONE SURFACE, so both props attach the same way: this zone is
          -- located by the RESULT TYPE 'Tpl Node' rather than by a row
          -- trace beside a template handle, and 'withTplAttrs' is the
          -- only way to reach a node. Rust spends its two surfaces here
          -- (the row trace carries inset, the Tpl carries role); the
          -- nesting below is the whole of it in Haskell.
          each heads $
            withTplAttrs [TplInset 8] $
              rowOf [withTplAttrs [TplRole Heading, TplA11yId element] (label element)]
        ]
    mount root

    -- The keys are the app's own, and arbitrary: a scalar collection
    -- has no minter in this binding ('insertFresh' is record-typed),
    -- and nothing in the scene reads a key. What identifies these two
    -- rows to the accessibility tree is their text, through the
    -- template above.
    insert notes (VStr "a") (VStr "First note")
    insert notes (VStr "b") (VStr "Second note")
    insert heads (VStr "h1") (VStr "Heading one")
    insert heads (VStr "h2") (VStr "Heading two")
