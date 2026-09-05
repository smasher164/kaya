(* The tooltips scene, OCaml port — guests/rust/tooltips.rs,
   tools/scenes/tooltips.steps, docs/tooltip-plan.md. *)

open Kaya_wire
open Kaya_app

type account = { name : string; note : string } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      let name_help = signal (Str "Your full name as it appears on the card") in
      let accounts = collection_of account_record in

      let root =
        column ~help:"The settings for this account" ~a11y_id:"settings"
          [
            button ~text:"Save" ~help:"Saves the draft to disk"    (* button#0 *)
              ~a11y_id:"save"
              ~on_click:(fun () ->
                write name_help (Str "Your name, as saved"));
            button ~text:"Discard" ~help:"Throws the draft away"   (* button#1 *)
              ~a11y_hint:"discard every change" ~a11y_id:"discard";
            entry ~help_bind:name_help ~a11y_id:"fullname";        (* entry#0 *)
            slider ~help:"How loud the preview plays"              (* slider#0 *)
              ~a11y_id:"volume" ~min:0.0 ~max:1.0 ~value:0.5;
            (* THE TRAILING [()] IS LOAD-BEARING inside an `each` body,
               where nothing checks the result: without it the label is a
               partial application the body discards and no copy stamps
               (docs/traps.md, the curried-children entry). *)
            each (record_handle accounts) (fun () ->
                Tpl.(
                  label ~bind_field:account_name ~help_field:account_note
                    ~a11y_id_field:account_name ()));
          ]
          ()
      in
      mount root;

      insert_record accounts (Str "a")
        { name = "a"; note = "The first account, opened in March" };
      insert_record accounts (Str "b")
        { name = "b"; note = "The second account, opened in May" });

  exit (run app)
