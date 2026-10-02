package dev.kaya.nfprobe;

import android.app.Activity;
import android.os.Bundle;
import android.os.LocaleList;
import android.text.InputType;
import android.util.Log;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.widget.EditText;
import android.widget.LinearLayout;
import java.text.ParsePosition;
import java.util.Locale;

public class Probe extends Activity {
    static final String[] CASES = { "34", "3.5", "3,5", "\u0663\u0664", "\u0663\u066b\u0665", "1.234", "1,234", "1,234.5", "1.234,5", "\u0661\u066c\u0662\u0663\u0664", "12,34", "1.2.3", "-3.5", "-3,5", "-\u0663\u066b\u0665", "\u0663.\u0665" };

    static String hex(String s) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) b.append(String.format("%04X ", (int) s.charAt(i)));
        return b.toString().trim();
    }

    static String whole(android.icu.text.NumberFormat f, String s) {
        ParsePosition at = new ParsePosition(0);
        Number n = f.parse(s, at);
        if (n == null || at.getErrorIndex() >= 0 || at.getIndex() != s.length()) return "null";
        return Double.toString(n.doubleValue());
    }
    static String prefix(android.icu.text.NumberFormat f, String s) {
        try { return Double.toString(f.parse(s).doubleValue()); } catch (Exception e) { return "null"; }
    }
    static String plain(String s) {
        try { return Double.toString(Double.parseDouble(s)); } catch (Exception e) { return "null"; }
    }

    EditText field(Locale hint) {
        EditText e = new EditText(this);
        if (hint != null) e.setImeHintLocales(new LocaleList(hint));
        e.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL | InputType.TYPE_NUMBER_FLAG_SIGNED);
        return e;
    }

    String viaIme(EditText e, String s) {
        e.setText("");
        e.requestFocus();
        InputConnection ic = e.onCreateInputConnection(new EditorInfo());
        ic.commitText(s, 1);
        return e.getText().toString();
    }

    String viaKeys(EditText e, String s) {
        e.setText("");
        e.requestFocus();
        KeyCharacterMap map = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);
        KeyEvent[] evs = map.getEvents(s.toCharArray());
        if (evs == null) return "<no keys>";
        for (KeyEvent ev : evs) e.dispatchKeyEvent(ev);
        return e.getText().toString();
    }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        String tag = getIntent().getStringExtra("locale");
        Locale loc = Locale.forLanguageTag(tag == null ? "en-US" : tag);
        Locale.setDefault(loc);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        EditText compat = field(null);
        EditText hinted = field(loc);
        col.addView(compat); col.addView(hinted);
        setContentView(col);
        String which = getIntent().getStringExtra("focus");
        android.icu.text.NumberFormat icu = android.icu.text.NumberFormat.getInstance(loc);
        android.icu.text.NumberFormat icuNoGroup = android.icu.text.NumberFormat.getInstance(loc);
        icuNoGroup.setGroupingUsed(false);
        android.icu.text.DecimalFormatSymbols sym = android.icu.text.DecimalFormatSymbols.getInstance(loc);
        Log.i("nfprobe", "BEGIN " + loc.toLanguageTag() + " decimal=" + hex(sym.getDecimalSeparatorString())
            + " group=" + hex(sym.getGroupingSeparatorString()) + " zero=" + hex(sym.getDigitStrings()[0])
            + " writes=" + icu.format(-1234.5) + " [" + hex(icu.format(-1234.5)) + "]"
            + " hinted_listener=" + android.text.method.DigitsKeyListener.getInstance(loc, true, true));
        for (String c : CASES) {
            String ci = viaIme(compat, c), hi = viaIme(hinted, c);
            String ck = viaKeys(compat, c), hk = viaKeys(hinted, c);
            Log.i("nfprobe", "CASE [" + c + "] (" + hex(c) + ")"
                + " | compat ime=[" + ci + "] keys=[" + ck + "]"
                + " | hinted ime=[" + hi + "] keys=[" + hk + "]"
                + " | icu_whole=" + whole(icu, c) + " icu_whole_nogroup(kaya)=" + whole(icuNoGroup, c)
                + " icu_prefix=" + prefix(icu, c) + " toDouble=" + plain(c));
        }
        Log.i("nfprobe", "END");
        if ("hinted".equals(which)) { hinted.setText(""); hinted.requestFocus(); }
        else if ("compat".equals(which)) { compat.setText(""); compat.requestFocus(); }
    }
}
