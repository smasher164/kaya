(* The toast scene, OCaml port — guests/rust/toast.rs,
   tools/scenes/toast.steps, docs/toast-plan.md §5. *)

open Kaya_app

type item = { title : string } [@@deriving kaya_gen]

let outcome = function
  | Toast_outcome.Action -> "action"
  | Toast_outcome.Closed -> "closed"

let () =
  let app = Kaya_app.create () in
  let answers = ref 0 in
  let undos = ref 0 in
  let held = ref None in

  build app (fun () ->
      let last = signal Scalar.Str "no answer yet" in
      let count = signal Scalar.Str "answers 0" in
      let undone = signal Scalar.Str "nothing undone" in
      let rows = signal Scalar.Str "Milk, Eggs, Bread" in
      let items = collection_of item_record in

      let titles () =
        match record_items items with
        | [] -> "empty"
        | all -> String.concat ", " (List.map (fun (_, i) -> i.title) all)
      in

      let answer text o =
        incr answers;
        write count (Printf.sprintf "answers %d" !answers);
        write last (Printf.sprintf "%s: %s" text (outcome o))
      in

      let toast ?action text () =
        let _, answered = show_toast ?action text in
        let* o = answered in
        answer text o
      in

      let on_delete () =
        match record_items items with
        | [] -> ()
        | (key, item) :: _ ->
            undoable ("delete " ^ item.title);
            remove (record_handle items) key;
            write rows (titles ());
            let text = "Deleted " ^ item.title in
            let _, answered = show_toast ~action:"Undo" ~undo:true text in
            let* o = answered in
            answer text o
      in

      let on_hold () =
        let id, answered = show_toast ~duration:Toast_duration.Long "Working" in
        held := Some id;
        let* o = answered in
        answer "Working" o
      in

      let on_dismiss () =
        match !held with
        | Some id ->
            held := None;
            dismiss_toast id
        | None -> ()
      in

      window ~title:"toast"
        ~menus:
          [
            menu ~label:"Edit"
              [
                item ~label:"Undo" ~role:Menu_role.Undo;
                item ~label:"Redo" ~role:Menu_role.Redo;
              ];
          ]
        ~on_undone:(fun label _ ->
          incr undos;
          write undone (Printf.sprintf "undone %d: %s" !undos label);
          write rows (titles ()))
        ();

      let root =
        column
          [
            label ~bind:last (* label#0 *);
            label ~bind:count (* label#1 *);
            label ~bind:undone (* label#2 *);
            label ~bind:rows (* label#3 *);
            button ~text:"show" ~on_click:(toast "Saved") (* button#0 *);
            button ~text:"first" ~on_click:(toast ~action:"Open" "First") (* button#1 *);
            button ~text:"second" ~on_click:(toast ~action:"Open" "Second") (* button#2 *);
            button ~text:"delete" ~on_click:on_delete (* button#3 *);
            button ~text:"hold" ~on_click:on_hold (* button#4 *);
            button ~text:"dismiss" ~on_click:on_dismiss (* button#5 *);
            each (record_handle items) (fun () ->
                Tpl.(row [ label ~bind_field:item_title ] ()));
          ]
          ()
      in
      mount root;
      List.iter
        (fun title -> insert_record items (Key.str title) { title })
        [ "Milk"; "Eggs"; "Bread" ]);

  exit (run app)
