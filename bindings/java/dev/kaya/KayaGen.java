package dev.kaya;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * The generator's marker: the declaration's shape decides what the kaya
 * annotation processor (tools/java-processor) emits — a sealed
 * interface is a sum, a record is a record. See DESIGN.md's KayaGen
 * section. Generated files are checked in; tools/gen-guests.py
 * regenerates and checks freshness.
 */
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.SOURCE)
public @interface KayaGen {
    /** The collection's key type, as the simple name of a boxed wire
     * key type: "String" or "Long". */
    String key() default "String";
}
