// The generator's marker, the one KayaGen story every language tells:
// the declaration's shape decides what is generated. [KayaGen] on an
// abstract record names a sum whose derived records, in declaration
// order, are its constructors; tools/kaya-csgen generates the
// collection factory (the one spelling of the constructor order) and
// the compile-total EachSum eliminator, whose required delegate
// parameters are named at the call site. [KayaGen] on a plain record
// generates the collection factory, exact-index field tokens, and a
// named-setter patch. Nothing is restated — the declaration is the
// schema. Generated files are checked in; tools/gen-guests.sh
// regenerates and checks freshness.
[System.AttributeUsage(System.AttributeTargets.Class)]
sealed class KayaGenAttribute : System.Attribute
{
}
