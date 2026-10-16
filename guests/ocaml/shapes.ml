(* The shapes scene, OCaml port — guests/rust/shapes.rs,
   tools/scenes/shapes.steps, docs/styling-pass-plan.md Y6. *)

open Kaya_app

type person = { name : string; face : bytes; phase : Image_phase.t } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in
  build app (fun () ->
      window ~title:"shapes" ~width:420.0 ~height:360.0 ();
      let art = asset_bytes (asset "covers/cover-600.jpg") in
      let photo = asset_bytes (asset "images/photo.jpg") in
      let people = collection_of person_record in
      let pictured (id, shape) () =
        image ~source:art ~max_width:48.0 ~max_height:48.0 ~fit:Fit.Cover ~shape ~a11y_id:id ()
      in
      let root =
        column ~spacing:16.0
          [
            row ~spacing:16.0
              (List.map pictured [ ("rect", `Rect); ("rounded", `Rounded); ("circle", `Circle) ]
              @ [ (fun () -> image ~source:photo ~max_width:48.0 ~max_height:48.0 ~shape:`Circle ~a11y_id:"wide" ()) ]);
            each (record_handle people) (fun () ->
                Tpl.(
                  row
                    [
                      image ~bind_field:person_face ~fit:Fit.Cover ~max_width:48.0 ~max_height:48.0
                        ~phase_field:person_phase ~shape:`Circle ~a11y_id:"avatar";
                      label ~bind_field:person_name;
                    ]
                    ()));
          ]
          ()
      in
      mount root;
      insert_record people (Key.str "a1") { name = "Ada"; face = Bytes.empty; phase = Image_phase.Loading });
  exit (run app)
