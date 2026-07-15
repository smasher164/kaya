(* The milestone-2 scene from OCaml, on the idiomatic surface
   (Kaya_app): typed handles instead of hand-numbered ids, closures
   instead of template_end bookkeeping, and click handlers instead of a
   hand-rolled dispatch loop. The wire vocabulary underneath (Kaya_wire)
   is generated from kaya::spec by kaya-bindgen.

   Build the library first (cargo build), then, from a scratch dir
   holding this file plus the contents of bindings/ocaml:
       ocamlfind ocamlopt -package ctypes,ctypes-foreign,threads.posix \
           -linkpkg kaya_ml_stubs.c kaya_wire.ml kaya_runtime.ml \
           kaya_app.ml milestone2.ml -o milestone2-ocaml *)

open Kaya_wire

let () =
  let app = Kaya_app.create () in

  let status, extras, step, groups, items, remove_button =
    Kaya_app.build app (fun tx ->
        let status = Kaya_app.signal tx (Str "step 0") in
        let extras = Kaya_app.signal tx (Bool false) in

        let column = Kaya_app.widget tx kind_column in
        let step = Kaya_app.widget tx kind_button in
        Kaya_app.set_text tx step "step";
        let status_label = Kaya_app.widget tx kind_label in
        Kaya_app.bind_text tx status_label status;

        let banner, () =
          Kaya_app.when_ tx extras (fun t ->
              let banner_label = Kaya_app.Tpl.widget t kind_label in
              Kaya_app.Tpl.set_text t banner_label "extras on")
        in

        let groups = Kaya_app.collection tx in
        let group_list, (items, remove_button) =
          Kaya_app.for_each tx groups (fun t ->
              let group_column = Kaya_app.Tpl.widget t kind_column in
              let name = Kaya_app.Tpl.widget t kind_label in
              Kaya_app.Tpl.bind_text_element t name;
              Kaya_app.Tpl.add_child t group_column name;

              let items = Kaya_app.Tpl.collection t in
              let item_list, remove_button =
                Kaya_app.Tpl.for_each t items (fun item ->
                    let row = Kaya_app.Tpl.widget item kind_column in
                    let text = Kaya_app.Tpl.widget item kind_label in
                    Kaya_app.Tpl.bind_text_element item text;
                    let remove_button = Kaya_app.Tpl.widget item kind_button in
                    Kaya_app.Tpl.set_text item remove_button "remove";
                    Kaya_app.Tpl.add_child item row text;
                    Kaya_app.Tpl.add_child item row remove_button;
                    remove_button)
              in
              Kaya_app.Tpl.add_child t group_column item_list;
              (items, remove_button))
        in

        Kaya_app.add_child tx column step;
        Kaya_app.add_child tx column status_label;
        Kaya_app.add_child tx column banner;
        Kaya_app.add_child tx column group_list;
        Kaya_app.mount tx column;
        (status, extras, step, groups, items, remove_button))
  in

  let steps = ref 0 in
  Kaya_app.on_click app step (fun tx ->
      incr steps;
      (match !steps with
      | 1 ->
          Kaya_app.insert tx groups [] (Str "g1") (Str "Work");
          Kaya_app.insert tx items [ Str "g1" ] (Str "a") (Str "send report");
          Kaya_app.insert tx items [ Str "g1" ] (Str "b") (Str "buy milk")
      | 2 ->
          Kaya_app.insert tx groups [] (Str "g2") (Str "Home");
          Kaya_app.insert tx items [ Str "g2" ] (Str "a") (Str "water plants");
          Kaya_app.update tx groups [] (Str "g1") (Str "Office")
      | _ -> ());
      Kaya_app.write tx extras (Bool (!steps = 1));
      Kaya_app.write tx status (Str (Printf.sprintf "step %d" !steps)));

  Kaya_app.on_click_node app remove_button (fun tx keys ->
      match keys with
      | [ Str group; Str item ] ->
          Kaya_app.remove tx items [ Str group ] (Str item);
          Kaya_app.write tx status (Str (Printf.sprintf "removed %s/%s" group item))
      | _ -> ());

  exit (Kaya_app.run app)
