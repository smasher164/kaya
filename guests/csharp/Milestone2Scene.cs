// The milestone-2 scene from C#, on the construction sugar: typed
// handles, constructors carrying their props, containers taking their
// children through a body lambda, and the template zone's own
// constructors instead of template_end bookkeeping. The wire
// vocabulary underneath (KayaWire.cs) is generated from kaya::spec by
// kaya-bindgen.
//
// WHAT THIS SCENE DOCUMENTS IS HOW OCCURRENCES REACH AN APP, and only
// that (DESIGN.md, the scope ratified 2026-08-05). The remove button is
// a STAMPED copy, so its handler is registered CENTRALLY, after the
// build, against the template node the build body handed back — and it
// arrives carrying that copy's key path, which is the only way to know
// WHICH remove was clicked. The live step button spells the other half
// of the same registry: its handler rides its constructor, because a
// live widget is its own noun. Both spellings put the same closure in
// the same table. Construction is the ordinary sugar every example that
// is not a C guest uses.
//
// A C# LAMBDA CAPTURES ITS ENCLOSING LOCALS BY REFERENCE, so the two
// handles the central registration needs — the per-group items
// collection and the stamped remove button — are assigned to the
// scene's own locals from inside the template bodies that build them.
// Java threads the same two handles out through one-slot arrays only
// because its lambdas cannot do this.
//
// AND THE APP NAMES EVERY KEY HERE, on purpose. "g1" and "a" are the
// app's own identity for a group and an item: the driver reaches back
// for g1 to rename it ("Work" -> "Office") and the expected verdict
// says "removed g2/a", so those names are data the app chose and still
// knows. InsertFresh answers the other case — a row with no identity of
// its own (EntryScene.cs, TodosScene.cs, docs/fresh-key-plan.md) — and
// minting here would only force the app to remember a name it had.
//
// Build the library first (cargo build / cargo xwin build --release),
// keep kaya.dll on PATH or set KAYA_LIB, then: dotnet run

static class Milestone2Scene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        Collection items = default;
        Node removeButton = default;

        int steps = 0;
        app.Build(tx =>
        {
            status = tx.Signal("step 0");
            // The step count as a signal, so the banner's condition is
            // a derived signal: `stepCount == 1` is Eq in operator
            // clothes, recomputed on every write — no hand-maintained
            // Bool, no handler line for it.
            var stepCount = tx.Signal(0);

            var groups = tx.Collection();

            // Auto-parenting puts the templates where they stand: the
            // When and the For are declared inside the column, between
            // their siblings, and parent themselves there.
            tx.Mount(tx.Column(() =>
            {
                tx.Button("step", t =>
                {
                    steps++;
                    if (steps == 1)
                    {
                        t.Insert(groups, "g1", "Work");
                        var todos = items.At("g1");
                        t.Insert(todos, "a", "send report");
                        t.Insert(todos, "b", "buy milk");
                    }
                    else if (steps == 2)
                    {
                        t.Insert(groups, "g2", "Home");
                        t.Insert(items.At("g2"), "a", "water plants");
                        t.Update(groups, "g1", "Office");
                    }
                    t.Write(stepCount, steps);
                    t.Write(status, $"step {steps}");
                });
                tx.Label(bind: status);
                tx.When(stepCount == 1, t => t.Label("extras on"));
                tx.Each(groups, group =>
                {
                    group.Column(() =>
                    {
                        // A scalar collection's element IS its one wire
                        // field, so the row's label addresses field 0 —
                        // the token is the address, and the constructor
                        // is the same Label the live zone uses.
                        group.Label(KayaRecords.FieldAt<string>(0));
                        items = group.Collection();
                        group.Each(items, item =>
                        {
                            item.Column(() =>
                            {
                                item.Label(KayaRecords.FieldAt<string>(0));
                                removeButton = item.Button("remove");
                            });
                        });
                    });
                });
            }));
        });

        app.OnClick(removeButton, (tx, keys) =>
        {
            string group = (string)keys[0];
            string item = (string)keys[1];
            // The instance handle names the target once; mutation and
            // read hang off the same value. The collection is the
            // model: the count read is the fold of the patches, this
            // one included.
            var todos = items.At(group);
            tx.Remove(todos, item);
            int left = tx.Count(todos);
            tx.Write(status, $"removed {group}/{item}, {left} left");
        });

        System.Environment.Exit(app.Run());
    }
}
