# open-panel-phone.xml — NOT RECOVERABLE, and what it measured

The file itself is gone for good. It was never written by a session; it was
produced by the Android emulator and pulled over adb, so no transcript holds
its bytes:

    adb -s emulator-5554 shell uiautomator dump /sdcard/open-panel.xml
    adb -s emulator-5554 pull /sdcard/open-panel.xml \
        .../scratchpad/open-panel-phone.xml (gone)

Source: `24aa5ebf-.../subagents/workflows/wf_cebfca56-011/agent-a5c32ffcc28163df6.jsonl`,
2026-08-10T06:15:50Z, the save-probe Android arm. It is a `uiautomator`
accessibility dump of the DocumentsUI **open** panel, taken 3s after launching
`dev.kaya.milestone2` with the `save` scene; `save-panel-phone.xml` is the same
dump 15s later, after the panel had switched to save.

## The measurement it was taken for (from the transcript, verbatim output)

Both dumps yield the SAME `resource-id` set:

    action_bar_root, app_bar, breadcrumb_arrow, breadcrumb_text,
    collapsing_toolbar, container_directory, container_save,
    container_search_fragment, content, coordinator_layout, date, details,
    dir_list, directory_header, drawer_edge, drawer_layout, header_container,
    header_title, horizontal_breadcrumb, icon, icon_mime_lg, icon_mime_sm,
    icon_thumb, item_root, nameplate, option_menu_search, preview_icon,
    refresh_layout, search_chip_group, sub_menu, sub_menu_list, thumbnail,
    title, toolbar

    open-panel-phone.xml  container_save present: True
    save-panel-phone.xml  container_save present: True

Matching nodes, identical in both:

    rid=android:id/title  cls=android.widget.TextView  text='decoy'  bounds=[74,372][111,391]
    rid=android:id/title  cls=android.widget.TextView  text='draft'  bounds=[214,372][245,391]
    rid=com.google.android.documentsui:id/container_save
        cls=android.view.ViewGroup  text=''  bounds=[0,616][320,640]

## The finding

`container_save` is present in the OPEN panel as well as the save panel, so it
cannot discriminate between the two dialogs. `ACTION_CREATE_DOCUMENT` is
DocumentsUI too — same package, same breadcrumb, same file list.

Immediately after this probe the agent rewrote the comment in
`android/kaya/src/main/kotlin/dev/kaya/KayaHarnessAccessibility.kt` from

    THE SAVE PANEL'S THREE NODES.

to

    THE SAVE PANEL'S TWO NODES, and the one that tells the two dialogs apart.

which is the durable form of this measurement. Read that comment for the
conclusion; this file is only the provenance behind it.
