(* The network images affordance scene, OCaml port — guests/rust/netimage.rs,
   tools/scenes/netimage.steps. No HTTP: each "download" is a job a worker
   thread holds until a click releases it. *)

open Kaya_app

type track = { title : string; art_url : string; art : bytes; phase : Image_phase.t }
[@@deriving kaya_gen]

type job = Live of bytes option | Row of string * string * bytes

let rows_count = 300

let jobs_lock = Mutex.create ()
let jobs_ready = Condition.create ()
let jobs : job list Queue.t = Queue.create ()

let send batch =
  Mutex.lock jobs_lock;
  Queue.push batch jobs;
  Condition.signal jobs_ready;
  Mutex.unlock jobs_lock

let () =
  let app = Kaya_app.create () in

  let art, phase, tracks =
    build app (fun () ->
        window ~title:"netimage" ~width:820.0 ~height:640.0 ();
        let covers =
          Array.map
            (fun name -> asset_bytes (asset name))
            [| "covers/cover-600.jpg"; "covers/cover-320.jpg"; "covers/cover-1000.jpg" |]
        in
        let art = signal Scalar.Bytes Bytes.empty in
        let phase = signal Scalar.Image_phase Image_phase.Loading in
        let band = signal Scalar.Str "band: -" in
        let released = signal Scalar.Str "released: none" in
        let again = signal Scalar.Str "again: none" in
        let tracks = collection_of track_record in

        let live = ref (Some (Live (Some covers.(0)))) in
        let pending = ref [] in
        let needed = Hashtbl.create 64 in
        let ever = Hashtbl.create 64 in
        let twice = ref None in

        let on_needed keys =
          let key = Key.text (List.hd keys) in
          if Hashtbl.mem needed key then (if !twice = None then twice := Some key)
          else Hashtbl.replace needed key ();
          Hashtbl.replace ever key ();
          let i = int_of_string (String.sub key 1 (String.length key - 1)) in
          pending := !pending @ [ Row (key, Printf.sprintf "u/%d" i, covers.(i mod 3)) ];
          let seen = Hashtbl.length ever in
          write band
            (if seen < rows_count then "band: partial" else Printf.sprintf "band: %d" seen);
          write again ("again: " ^ Option.value !twice ~default:"none")
        in
        let on_released keys =
          let key = Key.text (List.hd keys) in
          Hashtbl.remove needed key;
          pending := List.filter (function Row (k, _, _) -> k <> key | Live _ -> true) !pending;
          write released "released: some"
        in

        let table, _ =
          for_each (record_handle tracks)
            (fun () ->
              Tpl.(
                row
                  [
                    image ~bind_field:track_art ~fit:Fit.Cover ~max_width:40.0 ~max_height:40.0 ~shape:`Rounded
                      ~phase_field:track_phase ~a11y_id:"art" ~on_needed ~on_released;
                    label ~bind_field:track_title;
                  ]
                  ()))
            ()
        in
        columns table [ "Art"; "Title" ] sort_none;
        set_a11y_id table "tracks";
        set_grow table 1.0;

        let root =
          column
            [
              column
                [
                  image ~bind:art ~max_width:96.0 ~max_height:96.0 ~fit:Fit.Cover ~phase_bind:phase
                    ~a11y_id:"cover" ~a11y_label:"Cover";
                  row
                    [
                      button ~text:"release" ~a11y_id:"release" ~on_click:(fun () ->
                          match !live with
                          | Some job ->
                              live := None;
                              send [ job ]
                          | None -> ());
                      button ~text:"refresh" ~a11y_id:"refresh" ~on_click:(fun () ->
                          live := Some (Live (Some covers.(1)));
                          write phase Image_phase.Loading);
                    ];
                  row
                    [
                      button ~text:"junk" ~a11y_id:"junk" ~on_click:(fun () ->
                          write art (Bytes.of_string "not an image");
                          write phase Image_phase.Shown);
                      button ~text:"fail" ~a11y_id:"fail" ~on_click:(fun () ->
                          live := Some (Live None);
                          write art Bytes.empty;
                          write phase Image_phase.Loading);
                    ];
                  row
                    [
                      button ~text:"rows" ~a11y_id:"rows" ~on_click:(fun () ->
                          Hashtbl.reset needed;
                          let batch = !pending in
                          pending := [];
                          send batch);
                      button ~text:"delete" ~a11y_id:"delete" ~on_click:(fun () ->
                          remove (record_handle tracks) (Key.str "t299"));
                      button ~text:"retarget" ~a11y_id:"retarget" ~on_click:(fun () ->
                          pending := Row ("t298", "u/298b", covers.(2)) :: !pending;
                          track_patch ~art_url:"u/298b" tracks (Key.str "t298"));
                    ];
                  label ~bind:band ~a11y_id:"band";
                  label ~bind:released ~a11y_id:"released";
                  label ~bind:again ~a11y_id:"again";
                ];
              w table;
            ]
            ()
        in
        mount root;
        for i = 0 to rows_count - 1 do
          insert_record tracks
            (Key.str (Printf.sprintf "t%03d" i))
            {
              title = Printf.sprintf "Track %d" i;
              art_url = Printf.sprintf "u/%d" i;
              art = Bytes.empty;
              phase = Image_phase.Loading;
            }
        done;
        (art, phase, tracks))
  in

  let worker () =
    while true do
      Mutex.lock jobs_lock;
      while Queue.is_empty jobs do
        Condition.wait jobs_ready jobs_lock
      done;
      let batch = Queue.pop jobs in
      Mutex.unlock jobs_lock;
      List.iter
        (function
          | Live (Some bytes) ->
              post app (fun () ->
                  write art bytes;
                  write phase Image_phase.Shown)
          | Live None -> post app (fun () -> write phase Image_phase.Failed)
          | Row (key, url, bytes) ->
              post app (fun () ->
                  track_patch_if ~art:bytes ~phase:Image_phase.Shown ~guard:track_art_url
                    ~equals:url tracks (Key.str key)))
        batch
    done
  in
  ignore (Thread.create worker ());

  exit (run app)
