(* The commands scene, OCaml port — guests/rust/commands.rs,
   tools/scenes/commands.steps. *)

open Kaya_app

let () =
  let app = Kaya_app.create () in
  let settings_count = ref 0 in

  build app (fun () ->
     let status = signal Scalar.Str ("ready") in
     let details = signal Scalar.Bool (false) in
     let sort = signal Scalar.F64 (0.0) in

     window ~title:"commands"
       ~menus:
         [
           (* Reload keeps this menu non-empty once macOS moves Settings out. *)
           menu ~label:"File"
             [
               item ~label:"Reload";
               item ~label:"Settings…" ~shortcut:"primary+comma"
                 ~role:Menu_role.Settings
                 ~on_activate:(fun () ->
                   (* Fires twice on purpose: the chord and the declared
                      path. *)
                   incr settings_count;
                   write status ((Printf.sprintf "settings %d" !settings_count)));
             ];
           (* Option order IS the index vocabulary: Name = 0, Date = 1. *)
           menu ~label:"View"
             [
               toggle ~label:"Details" ~bind_checked:details
                 ~shortcut:"primary+backslash"
                 ~on_toggle:(fun on ->
                   write status
                     (if on then "details on" else "details off"));
               radio_group ~label:"Sort" ~bind_value:sort
                 ~on_select:(fun index ->
                   write status
                     (if index = 1 then "sorted date" else "sorted name"))
                 [
                   option ~label:"Name" ~shortcut:"primary+1";
                   option ~label:"Date" ~shortcut:"primary+2";
                 ];
             ];
         ]
       ();

     let root = column [ label ~bind:status (* label#0 *) ] () in
     mount root);

  exit (run app)
