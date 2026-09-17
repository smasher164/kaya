(* The milestone2 scene, OCaml port — guests/rust/milestone2.rs,
   tools/scenes/milestone2.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in

  let steps = ref 0 in
  let status, items, remove_button =
    build app (fun () ->
       let status = signal Scalar.Str ("step 0") in
       let extras = signal Scalar.Bool (false) in

       let groups = collection () in
       (* Both Fors keep their results because the central registration
          below needs the handles they carry. *)
       let group_list, (items, remove_button) =
         for_each groups (fun () ->
             Tpl.(
               let items = collection () in
               let name = label ~bind_field:element () in
               let item_list, (_cell, remove_button) =
                 for_each items (fun () ->
                     let text = label ~bind_field:element () in
                     let remove_button = button ~text:"remove" () in
                     let cell = column [ w text; w remove_button ] () in
                     (cell, remove_button)) ()
               in
               let _ = column [ w name; w item_list ] () in
               (items, remove_button))) ()
       in

       let on_step () =
         let n = (incr steps; !steps) in
         let () =
           match n with
           | 1 ->
               insert groups (Key.str "g1") "Work";
               let todos = at items (Key.str "g1") in
               insert todos (Key.str "a") "send report";
               insert todos (Key.str "b") "buy milk"
           | 2 ->
               insert groups (Key.str "g2") "Home";
               insert (at items (Key.str "g2")) (Key.str "a") "water plants";
               update groups (Key.str "g1") "Office"
           | _ -> ()
         in
         write extras ((n = 1));
         write status ((Printf.sprintf "step %d" n))
       in

       let root =
         column
           [
             button ~text:"step" ~on_click:on_step (* button#0 *);
             label ~bind:status (* label#0 *);
             when_ extras (fun () -> Tpl.(label ~text:"extras on" ()));
             w group_list;
           ]
           ()
       in
       mount root;
       (status, items, remove_button))
  in

  on_click_node app remove_button (fun keys ->
      match keys with
      | [ Key.Str group; Key.Str item ] ->
          let todos = at items (Key.str group) in
          remove todos (Key.str item);
          let left = count todos in
          write status ((Printf.sprintf "removed %s/%s, %d left" group item left))
      | _ -> ());

  exit (run app)
