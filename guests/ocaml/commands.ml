(* The standard-commands scene, OCaml port: a chord on every leaf kind
   (a checkable command, one option of a group, a plain command), the
   punctuation keys those chords need, and the [settings] role — which
   macOS shows in the application menu while the item stays addressable
   where it was declared. Canonical semantics in
   guests/rust/commands.rs; the byte-frozen contract in
   tools/scenes/commands.steps. *)

open Kaya_wire
open Kaya_app

let () =
  let app = Kaya_app.create () in
  let settings_count = ref 0 in

  build app (fun () ->
     let status = signal (Str "ready") in
     let details = signal (Bool false) in
     let sort = signal (F64 0.0) in

     window ~title:"commands"
       ~menus:
         [
           (* The settings command declares its own punctuation chord
              and the role that tells macOS where users look for it. An
              ordinary command sits beside it so the menu that declared
              it is not left empty once the platform moves it. *)
           menu ~label:"File"
             [
               item ~label:"Reload";
               item ~label:"Settings…" ~shortcut:"primary+comma"
                 ~role:role_settings
                 ~on_activate:(fun () ->
                   (* Fires twice on purpose: once by the chord, once by
                      activating the item at its DECLARED path — which on
                      macOS lives in the application menu by then. *)
                   incr settings_count;
                   write status (Str (Printf.sprintf "settings %d" !settings_count)));
             ];
           (* A checkable command carrying its own key, and a group whose
              options each answer their own chord. Option order IS the
              index vocabulary: Name = 0, Date = 1. *)
           menu ~label:"View"
             [
               toggle ~label:"Details" ~bind_checked:details
                 ~shortcut:"primary+backslash"
                 ~on_toggle:(fun on ->
                   write status
                     (Str (if on then "details on" else "details off")));
               radio_group ~label:"Sort" ~bind_value:sort
                 ~on_select:(fun index ->
                   write status
                     (Str (if index = 1 then "sorted date" else "sorted name")))
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
