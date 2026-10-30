(* The font picker scene, OCaml port: guests/rust/fontpick.rs,
   tools/scenes/fontpick.steps (docs/font-picker-plan.md §7). *)

open Kaya_app

let mono =
  [ "Menlo"; "DejaVu Sans Mono"; "Cascadia Mono"; "Consolas"; "Courier New"; "Droid Sans Mono"; "monospace" ]

let doc_text = "bold run, italic run, plain run"

let words weight italic width =
  Printf.sprintf "%d %s %d" weight (if italic then "italic" else "upright") width

let light_family (faces : Font_face.t list) =
  let upright = List.filter_map (fun (f : Font_face.t) -> if (not f.italic) && f.width = 5 then Some f.weight else None) faces in
  let slanted = List.filter_map (fun (f : Font_face.t) -> if f.italic && f.width = 5 then Some f.weight else None) faces in
  let rec pair = function
    | a :: (b :: _ as rest) -> if a >= 500 && b > a + 1 then Some (a, b) else pair rest
    | _ -> None
  in
  if List.length upright < 3 || not (List.mem 700 upright) then None
  else
    match (List.find_opt (fun w -> w < 400 && List.mem w slanted) upright, pair upright) with
    | Some light, Some (a, b) -> Some (light, a, b)
    | _ -> None

let upright_only (faces : Font_face.t list) =
  if faces = [] || List.exists (fun (f : Font_face.t) -> f.italic) faces then None
  else Option.map (fun (f : Font_face.t) -> f.weight) (List.find_opt (fun (f : Font_face.t) -> f.width = 5) faces)

let no_bold (faces : Font_face.t list) =
  faces <> [] && List.for_all (fun (f : Font_face.t) -> f.weight < 600) faces

let () =
  let app = Kaya_app.create () in
  let queue = ref [] in
  let light = ref None in
  let plain = ref None in
  let boldless = ref None in
  let mono_family = ref None in
  let asked : Font_choice.t option ref = ref None in
  let widgets = ref None in

  let next () =
    match !queue with
    | f :: rest ->
        queue := rest;
        list_font_faces f;
        true
    | [] -> false
  in

  on_font_families app (fun families ->
      mono_family := List.find_opt (fun m -> List.mem m families) mono;
      queue := Option.to_list !mono_family @ families;
      ignore (next ()));

  on_font_faces app (fun family faces ->
      (if Some family = !mono_family && !asked = None then
         let face =
           match List.find_opt (fun (f : Font_face.t) -> f.weight = 700 && (not f.italic) && f.width = 5) faces with
           | Some f -> Some f
           | None -> List.nth_opt faces 0
         in
         asked := Option.map (fun (f : Font_face.t) -> { Font_choice.family; weight = f.weight; italic = f.italic; width = f.width }) face);
      if !light = None then light := Option.map (fun l -> (family, l)) (light_family faces);
      if !plain = None then plain := Option.map (fun w -> (family, w)) (upright_only faces);
      if !boldless = None && no_bold faces then boldless := Some family;
      match (!widgets, !light, !plain, !boldless) with
      | Some (_, want, pick, _, exact, between, synth, heavy, doc, _), Some (lf, (lw, a, b)), Some (pf, pw), Some hf ->
          set_family exact lf;
          set_font_weight exact lw;
          set_family between lf;
          set_font_weight between (a + ((b - a) / 2));
          set_family synth pf;
          set_font_weight synth pw;
          set_font_italic synth true;
          set_family heavy hf;
          set_font_weight heavy 700;
          set_family doc lf;
          set_font_weight doc lw;
          set_document doc (Document.create doc_text |> Document.bold (0, 4) |> Document.italic (10, 16));
          let say i s = write (List.nth want i) s in
          say 0 (words lw false 5);
          say 1 (words b false 5);
          say 2 (words pw true 5 ^ " synthesized");
          say 3 (words 700 false 5);
          say 4 (words lw true 5);
          say 6 (words 700 false 5 ^ " synthesized");
          Option.iter
            (fun (c : Font_choice.t) ->
              write pick (words c.weight c.italic c.width ^ " " ^ c.family);
              say 5 (words c.weight c.italic c.width))
            !asked;
          Option.iter (fun (ready, _, _, _, _, _, _, _, _, _) -> write ready "faces: found") !widgets
      | Some (ready, _, _, _, _, _, _, _, _, _), _, _, _ -> if not (next ()) then write ready "faces: none suit"
      | None, _, _, _ -> ());

  let on_chosen choice =
    match !widgets with
    | None -> ()
    | Some (_, _, _, picked, _, _, _, _, _, chosen) -> (
        match choice with
        | None -> write picked "picked: cancelled"
        | Some (c : Font_choice.t) ->
            set_family chosen c.family;
            set_font_weight chosen c.weight;
            set_font_italic chosen c.italic;
            set_font_width chosen c.width;
            write picked
              (if Some c = !asked then "picked: as asked"
               else "picked: " ^ words c.weight c.italic c.width ^ " " ^ c.family))
  in

  build app (fun () ->
      window ~title:"fontpick" ();
      let ready = signal Scalar.Str "faces: -" in
      let want = List.init 7 (fun _ -> signal Scalar.Str "-") in
      let pick = signal Scalar.Str "-" in
      let picked = signal Scalar.Str "picked: -" in
      let ready_label = label ~bind:ready ~a11y_id:"ready" () in
      let exact = label ~text:"Exact" ~a11y_id:"exact" () in
      let between = label ~text:"Between" ~a11y_id:"between" () in
      let synth = label ~text:"Slanted" ~a11y_id:"synth" () in
      let heavy = entry ~a11y_id:"heavy" () in
      set_text heavy "Heavy";
      let doc = textarea ~rich:true ~a11y_id:"doc" () in
      let chosen = label ~text:"Chosen" ~a11y_id:"chosen" () in
      widgets := Some (ready, want, pick, picked, exact, between, synth, heavy, doc, chosen);
      mount
        (column
           ([ w ready_label; w exact; w between; w synth; w heavy; w doc; w chosen ]
           @ List.map2
               (fun s id -> w (label ~bind:s ~a11y_id:id ()))
               want
               [ "want_exact"; "want_between"; "want_synth"; "want_bold"; "want_italic"; "want_pick"; "want_heavy" ]
           @ [
               w (label ~bind:pick ~a11y_id:"pick" ());
               w (label ~bind:picked ~a11y_id:"picked" ());
               row
                 [
                   button ~text:"faces" ~a11y_id:"faces" ~on_click:list_font_families;
                   button ~text:"pick" ~a11y_id:"pick_button" ~on_click:(fun () ->
                       choose_font ~code_only:true ~faces:true ?initial:!asked () on_chosen);
                 ];
             ])
           ()));

  exit (run app)
