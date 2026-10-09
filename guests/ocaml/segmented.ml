(* The segmented control scene, OCaml port — guests/rust/segmented.rs,
   tools/scenes/segmented.steps, docs/segmented-plan.md §5. *)

open Kaya_app

type habit = { name : string; cadence : float } [@@deriving kaya_gen]

let periods = [ "Day"; "Week"; "Month" ]
let views = [ ("Info", Info); ("Edit", Edit) ]
let cadences = [ "Daily"; "Weekly" ]

let () =
  let app = Kaya_app.create () in
  let heard = ref 0 in

  build app (fun () ->
      window ~title:"segmented" ();
      let period = signal Scalar.F64 0.0 in
      let period_text = signal Scalar.Str "period: Day" in
      let heard_text = signal Scalar.Str "heard: 0" in
      let view_text = signal Scalar.Str "view: Edit" in
      let cadence_text = signal Scalar.Str "cadence: -" in
      let habits = collection_of habit_record in

      let root =
        column
          [
            segmented ~a11y_id:"period" ~a11y_label:"Period" ~bind:period
              ~on_select:(fun index ->
                incr heard;
                write period (float_of_int index);
                write period_text ("period: " ^ List.nth periods index);
                write heard_text (Printf.sprintf "heard: %d" !heard))
              periods;
            label ~bind:period_text;
            label ~bind:heard_text;
            button ~text:"Reset" ~a11y_id:"reset"
              ~on_click:(fun () ->
                write period 0.0;
                write period_text "period: Day");
            segmented_symbols ~a11y_id:"view" ~a11y_label:"View" ~selected:1
              ~on_select:(fun index ->
                write view_text ("view: " ^ fst (List.nth views index)))
              views;
            label ~bind:view_text;
            label ~bind:cadence_text;
            each (record_handle habits) (fun () ->
                Tpl.(
                  column
                    [
                      label ~bind_field:habit_name;
                      segmented ~a11y_id:"cadence" ~bind_field:habit_cadence
                        ~on_select:(fun keys index ->
                          let key = key_text (List.hd keys) in
                          write cadence_text
                            (Printf.sprintf "cadence %s: %s" key
                               (List.nth cadences index)))
                        cadences;
                    ]
                    ()));
          ]
          ()
      in
      mount root;

      insert_record habits (Key.str "read") { name = "read"; cadence = 1.0 };
      insert_record habits (Key.str "walk") { name = "walk"; cadence = 0.0 });

  exit (run app)
