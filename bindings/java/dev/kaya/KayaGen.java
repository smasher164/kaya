package dev.kaya;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * The generator's marker, the one KayaGen story every language tells:
 * the declaration's shape decides what is generated. On a sealed
 * interface (a sum: the permitted records, in permits-clause order,
 * are its constructors), the kaya annotation processor
 * (tools/java-processor) generates {@code <Sum>Kaya}: the collection
 * factory — the one spelling of the constructor order — and the
 * staged-builder eliminator, whose stages make template totality a
 * compile error. On a record, it generates the collection factory,
 * exact-index field tokens, and a named-setter patch. Nothing is
 * restated — the declaration is the schema. Generated files are
 * checked in; tools/gen-guests.sh regenerates and checks freshness.
 */
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.SOURCE)
public @interface KayaGen {
    /** The collection's key type, as the simple name of a boxed wire
     * key type: "String" or "Long". */
    String key() default "String";
}
