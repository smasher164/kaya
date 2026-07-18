(* The feed scene from OCaml: sum-typed elements, end to end. The
   variant declaration is the sum ([@@deriving kaya] over constructors
   carrying inline records); the generated post_each eliminator takes
   one REQUIRED labelled arm per constructor — template totality is a
   compile error here, and the scene checks it again. Handlers
   eliminate with match, and the generated per-constructor patches
   witness that match: a drifted entry is refused, so a stale
   occurrence folds into nothing.

   Build like milestone2.ml, then run with KAYA_SELFTEST=feed. *)

open Kaya_wire
open Kaya_app

type post =
  | Note of { text : string }
  | Todo of { title : string; done_ : bool }
[@@deriving kaya]

let () =
  let app = Kaya_app.create () in

  build app
    (let* feed = sum_of post_sum in
     let* done_count =
       sum_derive feed (fun entries ->
           let n =
             List.length
               (List.filter
                  (fun (_, p) -> match p with Todo { done_; _ } -> done_ | _ -> false)
                  entries)
           in
           Str (Printf.sprintf "%d done" n))
     in
     let on_promote =
       (* The first note, promoted to a finished todo: the model is
          asked which entry is a Note, and the update's new constructor
          restamps that key's copy in place. *)
       let* entries = sum_items feed in
       match
         List.find_opt (fun (_, p) -> match p with Note _ -> true | _ -> false) entries
       with
       | Some (key, Note { text }) ->
           sum_update feed key (Todo { title = text; done_ = true })
       | _ -> fun _ -> ()
     in
     let on_toggle keys checked =
       (* The match is the refinement; the generated patch witnesses
          it. A stale occurrence lands in the other arm. *)
       let* post = sum_get feed (List.hd keys) in
       match post with
       | Some (Todo _) -> post_todo_patch ~done_:checked feed (List.hd keys)
       | _ -> fun _ -> ()
     in

     let* root =
       row
         [
           button ~text:"promote" ~on_click:on_promote ();
           label ~bind:done_count ();
           post_each feed
             ~note:
               Tpl.(
                 let+ _ = label ~bind_field:post_note_text () in
                 ())
             ~todo:
               Tpl.(
                 let+ _ =
                   row
                     [
                       checkbox ~checked_field:post_todo_done_ ~on_toggle ();
                       label ~bind_field:post_todo_title ();
                     ]
                 in
                 ());
         ]
     in
     let* () = mount root in
     let* () = sum_insert feed (Str "a") (Note { text = "jot one" }) in
     let* () = sum_insert feed (Str "b") (Todo { title = "buy milk"; done_ = false }) in
     sum_insert feed (Str "c") (Note { text = "jot two" }));

  exit (run app)
