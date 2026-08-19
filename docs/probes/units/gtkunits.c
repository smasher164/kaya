/* What unit does GTK4 count? Measured, not assumed. */
#include <gtk/gtk.h>
#include <string.h>

static const char *NAMES[] = { "EMOJI  ab<U+1F600>cd", "COMBIN abe<U+0301>cd",
                               "ZWJ    ab<family>cd",  "CJK    ab<3 han>cd",
                               "CRLF   ab<CR><LF>cd" };
static const char *CASES[] = {
    "ab\xF0\x9F\x98\x80" "cd",
    "abe\xCC\x81" "cd",
    "ab\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7\xE2\x80\x8D\xF0\x9F\x91\xA6" "cd",
    "ab\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E" "cd",
    "ab\r\ncd"
};

int main(void) {
    if (!gtk_init_check()) { g_printerr("no display\n"); return 2; }
    GtkTextTagTable *tt = gtk_text_tag_table_new();
    for (int c = 0; c < 5; c++) {
        const char *s = CASES[c];
        g_print("### %s\n", NAMES[c]);
        g_print("  strlen(utf8 bytes)=%zu g_utf8_strlen(code points)=%ld\n",
                strlen(s), (long)g_utf8_strlen(s, -1));

        GtkTextBuffer *buf = gtk_text_buffer_new(tt);
        gtk_text_buffer_set_text(buf, s, -1);
        g_print("  gtk_text_buffer_get_char_count=%d\n", gtk_text_buffer_get_char_count(buf));

        /* what a buffer OFFSET addresses: iterate every offset and print
           the byte index it lands on */
        g_print("  offset -> byte_index_in_line/line, char:");
        for (int off = 0; off <= gtk_text_buffer_get_char_count(buf); off++) {
            GtkTextIter it;
            gtk_text_buffer_get_iter_at_offset(buf, &it, off);
            g_print(" [%d->b%d]", off, gtk_text_iter_get_line_index(&it));
        }
        g_print("\n");

        /* PAST THE END: docs say it clamps; measure. */
        GtkTextIter over;
        gtk_text_buffer_get_iter_at_offset(buf, &over, 9999);
        g_print("  get_iter_at_offset(9999) -> offset=%d (char_count=%d)  is_end=%d\n",
                gtk_text_iter_get_offset(&over), gtk_text_buffer_get_char_count(buf),
                gtk_text_iter_is_end(&over));

        /* NEGATIVE / mid-sequence byte index: the byte-addressed door.
           gtk_text_buffer_get_iter_at_line_index takes a BYTE index. */
        GtkTextIter bi;
        gtk_text_buffer_get_iter_at_line_index(buf, &bi, 0, 3);
        g_print("  get_iter_at_line_index(line 0, BYTE 3) -> char offset=%d, byte=%d\n",
                gtk_text_iter_get_offset(&bi), gtk_text_iter_get_line_index(&bi));

        /* CURSOR POSITIONS = what GTK calls a user-visible character */
        GtkTextIter cur;
        gtk_text_buffer_get_start_iter(buf, &cur);
        int steps = 0;
        while (gtk_text_iter_forward_cursor_position(&cur)) steps++;
        g_print("  forward_cursor_position steps end-to-end=%d (char_count=%d)\n",
                steps, gtk_text_buffer_get_char_count(buf));

        /* A TAG over a range that splits a GRAPHEME (offset 2..3) */
        GtkTextTag *tag = gtk_text_buffer_create_tag(buf, NULL, "background", "yellow", NULL);
        GtkTextIter a, b;
        gtk_text_buffer_get_iter_at_offset(buf, &a, 2);
        gtk_text_buffer_get_iter_at_offset(buf, &b, 3);
        gtk_text_buffer_apply_tag(buf, tag, &a, &b);
        g_print("  apply_tag over char offsets {2,3}: applied=%d (no validation call available)\n",
                gtk_text_iter_has_tag(&a, tag));

        /* SELECTION over the same split */
        gtk_text_buffer_select_range(buf, &a, &b);
        GtkTextIter sa, sb;
        gtk_text_buffer_get_selection_bounds(buf, &sa, &sb);
        g_print("  select_range{2,3} readback {%d,%d}  (SNAPPED? compare to {2,3})\n",
                gtk_text_iter_get_offset(&sa), gtk_text_iter_get_offset(&sb));
        g_object_unref(buf);

        /* PANGO: attribute indices are BYTES. Split one. */
        GtkWidget *lbl = gtk_label_new("x");
        PangoContext *pc = gtk_widget_create_pango_context(lbl);
        PangoLayout *lay = pango_layout_new(pc);
        pango_layout_set_text(lay, s, -1);
        PangoAttrList *al = pango_attr_list_new();
        PangoAttribute *at = pango_attr_background_new(65535, 65535, 0);
        at->start_index = 2;    /* inside the multi-byte sequence for most cases */
        at->end_index = 3;
        pango_attr_list_insert(al, at);
        pango_layout_set_attributes(lay, al);
        int w = 0, h = 0;
        pango_layout_get_pixel_size(lay, &w, &h);
        g_print("  pango attr over BYTES {2,3} (mid-sequence for non-ASCII): laid out %dx%d, no error return\n", w, h);
        pango_attr_list_unref(al);
        g_object_unref(lay);
        g_object_unref(pc);
        g_object_ref_sink(lbl); g_object_unref(lbl);
        g_print("\n");
    }
    /* gtk_editable_select_region's unit, from the live entry */
    GtkWidget *e = gtk_entry_new();
    gtk_editable_set_text(GTK_EDITABLE(e), CASES[0]);
    gtk_editable_select_region(GTK_EDITABLE(e), 2, 3);
    int ss = 0, se = 0;
    gtk_editable_get_selection_bounds(GTK_EDITABLE(e), &ss, &se);
    g_print("### ENTRY gtk_editable_select_region(2,3) on 'ab<emoji>cd' -> readback {%d,%d}\n", ss, se);
    gtk_editable_select_region(GTK_EDITABLE(e), 0, -1);
    gtk_editable_get_selection_bounds(GTK_EDITABLE(e), &ss, &se);
    g_print("### ENTRY select_region(0,-1) select-all -> {%d,%d}  (5 = code points, 8 = bytes)\n", ss, se);
    g_print("DONE\n");
    return 0;
}
