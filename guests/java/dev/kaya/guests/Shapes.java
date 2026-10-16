package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.Fit;
import dev.kaya.KayaApp.ImagePhase;
import dev.kaya.KayaApp.Shape;
import dev.kaya.KayaGen;

/** The shapes scene from the JVM — guests/rust/shapes.rs, tools/scenes/shapes.steps. */
public final class Shapes {
    @KayaGen(key = "String")
    record AvatarPerson(String name, byte[] face, ImagePhase phase) {}

    public static void app() {
        KayaApp app = new KayaApp();
        byte[] art;
        byte[] photo;
        try (KayaApp.Asset a = KayaApp.asset("covers/cover-600.jpg")) {
            art = a.bytes();
        }
        try (KayaApp.Asset a = KayaApp.asset("images/photo.jpg")) {
            photo = a.bytes();
        }
        app.build(tx -> {
            tx.window(0).title("shapes").size(420.0, 360.0);
            var people = AvatarPersonKaya.collection(tx);
            tx.mount(tx.column(root -> {
                tx.row(strip -> {
                    String[] ids = {"rect", "rounded", "circle"};
                    Shape[] shapes = {Shape.RECT, Shape.ROUNDED, Shape.CIRCLE};
                    for (int i = 0; i < ids.length; i++) {
                        KayaApp.Signal<byte[]> bytes = tx.signal(art);
                        tx.image(bytes).maxWidth(48).maxHeight(48).fit(Fit.COVER).shape(shapes[i]).a11yId(ids[i]);
                    }
                    KayaApp.Signal<byte[]> wide = tx.signal(photo);
                    tx.image(wide).maxWidth(48).maxHeight(48).shape(Shape.CIRCLE).a11yId("wide");
                }).spacing(16);
                for (var row : AvatarPersonKaya.rows(tx, people)) {
                    row.row(() -> {
                        KayaApp.Node face = row.image(row.face);
                        row.setFit(face, Fit.COVER);
                        row.setMaxWidth(face, 48);
                        row.setMaxHeight(face, 48);
                        row.setPhase(face, row.phase);
                        row.setShape(face, Shape.CIRCLE);
                        row.setA11yId(face, "avatar");
                        row.label(row.name);
                    });
                }
            }).spacing(16));
            people.insert(tx, "a1", new AvatarPerson("Ada", new byte[0], ImagePhase.LOADING));
            return null;
        });
        app.dispatchLoop();
    }

    private Shapes() {}
}
