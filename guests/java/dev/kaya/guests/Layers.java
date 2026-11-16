package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.Align;
import dev.kaya.KayaApp.Place;
import dev.kaya.KayaApp.Tint;

/** The layers scene from the JVM — guests/rust/layers.rs, tools/scenes/layers.steps. */
public final class Layers {
    public static void app() {
        KayaApp app = new KayaApp();
        byte[] cover;
        byte[] small;
        try (KayaApp.Asset a = KayaApp.asset("covers/cover-600.jpg")) {
            cover = a.bytes();
        }
        try (KayaApp.Asset a = KayaApp.asset("covers/cover-320.jpg")) {
            small = a.bytes();
        }
        java.util.List<String> log = new java.util.ArrayList<>(java.util.List.of("taps:"));
        app.build(tx -> {
            tx.window(0).title("layers").size(480.0, 860.0);
            KayaApp.Signal<String> answered = tx.signal("taps:");
            KayaApp.Signal<Boolean> veiled = tx.signal(false);
            java.util.function.BiConsumer<KayaApp.Widget, String> answers = (button, word) ->
                app.onClick(button, t -> {
                    log.add(word);
                    t.write(answered, String.join(" ", log));
                    if (word.equals("hide")) {
                        t.write(veiled, true);
                    }
                });
            tx.mount(tx.column(root -> {
                tx.layers(stack -> {
                    tx.image(cover).maxWidth(320).a11yLabel("Kind of Blue cover").a11yId("photo");
                    tx.row(badge -> {
                        tx.label("3").a11yId("badge_text");
                    }).filled(Tint.ACCENT).place(Place.TOP_TRAILING).a11yId("badge");
                    tx.row(caption -> {
                        tx.label("Kind of Blue").grow(1.0).a11yId("caption_text");
                        answers.accept(tx.button("Share").a11yId("share"), "share");
                    }).filled(Tint.OVERLAY_FADE).place(Place.BOTTOM).a11yId("caption");
                }).inset(8).a11yId("photostack");
                tx.layers(stack -> {
                    answers.accept(tx.button("Press the base button here").a11yId("base"), "base");
                    tx.column(veil -> {
                        tx.row(panel -> {
                            tx.label("Busy");
                        }).filled(Tint.OVERLAY);
                    }).align(Align.CENTER).fill(true).hidden(veiled).a11yId("busy");
                }).a11yId("veilstack");
                tx.layers(stack -> {
                    answers.accept(tx.button("Open the inbox").a11yId("side"), "side");
                    tx.row(badge -> {
                        tx.label("5");
                    }).filled(Tint.ACCENT).place(Place.TRAILING).a11yId("sidebadge");
                }).a11yId("sidestack");
                tx.layers(stack -> {
                    tx.image(small).maxWidth(200).a11yLabel("Small cover").a11yId("smallphoto");
                    tx.row(flat -> {
                        tx.label("Flat panel").a11yId("flat_text");
                    }).filled(Tint.OVERLAY).place(Place.TOP_LEADING).a11yId("flat");
                }).inset(8).a11yId("flatstack");
                tx.label(answered).a11yId("answered");
                answers.accept(tx.button("Hide the veil").a11yId("hideveil"), "hide");
            }).spacing(16));
            return null;
        });
        app.dispatchLoop();
    }

    private Layers() {}
}
