package dev.kaya.clipprobe

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.io.FileDescriptor
import java.io.FileInputStream

/**
 * What ART charges for BUILDING a java.io.FileDescriptor around a raw
 * integer fd — what KayaRing.openPicked must do (findings:
 * docs/clipboard-plan.md).
 *
 * F1  getDeclaredField("descriptor") — visible? settable?
 * F2  getMethod("setInt$")/getInt$ — visible? callable?
 * F3  the arm-shaped roundtrip: Os.open a real file, wrap the raw int
 *     in a hand-built FileDescriptor, read the bytes back through a
 *     FileInputStream over it.
 */
class FdReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val out = StringBuilder()

        // F1: the field, as libnativehelper's own
        // jniCreateFileDescriptor touches it.
        out.append("F1=")
        try {
            val f = FileDescriptor::class.java.getDeclaredField("descriptor")
            f.isAccessible = true
            val fd = FileDescriptor()
            f.setInt(fd, 41)
            out.append(if (f.getInt(fd) == 41) "field-ok" else "field-wrong-value")
        } catch (t: Throwable) {
            out.append("field-denied:${t.javaClass.simpleName}")
        }

        // F2: the accessor pair.
        out.append(" F2=")
        try {
            val set = FileDescriptor::class.java.getMethod("setInt\$", Int::class.javaPrimitiveType)
            val get = FileDescriptor::class.java.getMethod("getInt\$")
            val fd = FileDescriptor()
            set.invoke(fd, 42)
            out.append(if (get.invoke(fd) == 42) "setint-ok" else "setint-wrong-value")
        } catch (t: Throwable) {
            out.append("setint-denied:${t.javaClass.simpleName}")
        }

        // F3: the roundtrip the arm needs to be true.
        out.append(" F3=")
        try {
            val file = java.io.File(context.cacheDir, "fdprobe.txt")
            file.writeText("payload-crosses")
            val real = android.system.Os.open(file.absolutePath, android.system.OsConstants.O_RDONLY, 0)
            val rawField = FileDescriptor::class.java.getDeclaredField("descriptor")
            rawField.isAccessible = true
            val raw = rawField.getInt(real)
            val wrapped = FileDescriptor()
            rawField.setInt(wrapped, raw)
            val text = FileInputStream(wrapped).bufferedReader().readText()
            android.system.Os.close(real)
            out.append(if (text == "payload-crosses") "roundtrip-ok" else "roundtrip-wrong:'$text'")
        } catch (t: Throwable) {
            out.append("roundtrip-failed:${t.javaClass.simpleName}:${t.message}")
        }

        resultData = out.toString()
    }
}
