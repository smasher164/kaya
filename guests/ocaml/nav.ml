(* The nav conformance scene, OCaml port — the serial navigation
   grammar via labeled arguments: [push_entry ~title ~intercept_back]
   plus [mount_in] presents each screen, [on_entry_popped] hears the
   user's native pop, and [on_back_requested] answers the
   intercept_back veto with [pop_entry]. The covered root is RETAINED
   (status keeps taking writes while covered); a programmatic
   [pop_entry] does not echo entry_popped, so the settings round's
   final status stays "back requested". See guests/rust/nav.rs and
   tools/scenes/nav.steps. *)

open Kaya_wire
open Kaya_app

let detail = 7L
let settings = 8L

let () =
  let app = Kaya_app.create () in

  let status = ref None in
  build app
    (let* () = window_title "nav" in
     let* s = signal (Str "at root") in
     status := Some s;
     let on_detail tx =
       (* The popped handler rides the push (per-entry, the
          ~on_result precedent): it can only ever mean the detail
          screen popped, and it retires with the one pop. *)
       push_entry ~title:"detail"
         ~on_popped:(fun tx -> write s (Str "popped detail") tx)
         detail tx;
       (let* caption = signal (Str "detail pane") in
        let* pane = column [ label ~bind:caption () ] in
        let* () = mount_in detail pane in
        (* The covered root keeps taking writes — retention,
           observable after the pop. *)
        write s (Str "pushed detail"))
         tx
     in
     let on_settings tx =
       (* The veto class: nothing has popped; agree and confirm. No
          entry_popped will fire — the write is the round's final
          status. *)
       push_entry ~title:"settings" ~intercept_back:true
         ~on_back_requested:(fun tx ->
           write s (Str "back requested") tx;
           pop_entry () tx)
         settings tx;
       (let* caption = signal (Str "settings pane") in
        let* pane = column [ label ~bind:caption () ] in
        let* () = mount_in settings pane in
        write s (Str "pushed settings"))
         tx
     in
     let* root =
       column
         [
           label ~bind:s () (* label#0 *);
           button ~text:"open detail" ~on_click:on_detail ();
           button ~text:"open settings" ~on_click:on_settings ();
         ]
     in
     mount root);

  (* The handlers ride each push above; nothing app-global remains. *)
  ignore !status;

  exit (run app)
