// The generator's marker: the declaration's shape decides what
// tools/kaya-csgen emits (abstract record = sum, plain record =
// record). See DESIGN.md's KayaGen section. Generated files are checked
// in; tools/gen-guests.py regenerates and checks freshness.
[System.AttributeUsage(System.AttributeTargets.Class)]
sealed class KayaGenAttribute : System.Attribute
{
}
