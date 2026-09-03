(* The feed scene, OCaml port — guests/rust/feed.rs, tools/scenes/feed.steps. *)

open Kaya_wire
open Kaya_app

type post =
  | Note of { text : string }
  | Todo of { title : string; done_ : bool }
[@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
     let feed = sum_of post_sum in
     let done_count =
       sum_derive feed (fun entries ->
           let n =
             List.length
               (List.filter
                  (fun (_, p) -> match p with Todo { done_; _ } -> done_ | _ -> false)
                  entries)
           in
           Str (Printf.sprintf "%d done" n))
     in
     let on_promote () =
       let entries = sum_items feed in
       match
         List.find_opt (fun (_, p) -> match p with Note _ -> true | _ -> false) entries
       with
       | Some (key, Note { text }) ->
           sum_update feed key (Todo { title = text; done_ = true })
       | _ -> ()
     in
     let on_toggle keys checked =
       (* The match is the refinement and the generated patch witnesses it. *)
       let post = sum_get feed (List.hd keys) in
       match post with
       | Some (Todo _) -> post_todo_patch ~done_:checked feed (List.hd keys)
       | _ -> ()
     in

     let root =
       row
         [
           button ~text:"promote" ~on_click:on_promote;
           label ~bind:done_count;
           post_each feed
             ~note:(fun () -> Tpl.(label ~bind_field:post_note_text ()))
             ~todo:(fun () ->
               Tpl.(
                 row
                   [
                     checkbox ~bind_field:post_todo_done_ ~on_toggle;
                     label ~bind_field:post_todo_title;
                   ]
                   ()));
         ]
         ()
     in
     mount root;
     sum_insert feed (Str "a") (Note { text = "jot one" });
     sum_insert feed (Str "b") (Todo { title = "buy milk"; done_ = false });
     sum_insert feed (Str "c") (Note { text = "jot two" }));

  exit (run app)
