(* The capture, OCaml port — guests/rust/capture.rs,
   tools/scenes/capture.steps and capture_denied.steps, docs/capture-plan.md. *)

open Kaya_app

let camera_1 = "kaya-synthetic-camera-1"
let camera_2 = "kaya-synthetic-camera-2"
let microphone_1 = "kaya-synthetic-microphone-1"
let microphone_2 = "kaya-synthetic-microphone-2"

let state_line (r : Capture_reading.t) =
  match r.state with
  | Capture_state.Running -> Printf.sprintf "running %dx%d@%d" r.width r.height r.frame_rate
  | Capture_state.Failed -> "failed " ^ Option.fold ~none:"" ~some:Capture_failure.name r.failure
  | Capture_state.Interrupted -> "interrupted " ^ Option.fold ~none:"" ~some:Capture_interruption.name r.interruption
  | other -> Capture_state.name other

let evidence frames chunk =
  let frames = Option.fold ~none:"app frames none" ~some:(fun (w, h) -> Printf.sprintf "app frames %dx%d" w h) frames in
  let chunks = Option.fold ~none:"app chunks none" ~some:(Printf.sprintf "app chunks of %d") chunk in
  frames ^ ", " ^ chunks

let device_line (d : Capture_device.t) =
  Capture_kind.name d.kind ^ " " ^ d.id
  ^ (if d.kind = Capture_kind.Camera then " " ^ Camera_facing.name d.facing else "")
  ^ if d.preferred then " preferred" else ""

let () =
  let app = create () in
  let labels, call, missing =
    build app (fun () ->
        window ~title:"capture" ~width:520.0 ~height:640.0 ();
        let labels =
          Array.map (signal Scalar.Str) [| "devices"; "permissions"; "idle"; evidence None None; "idle" |]
        in
        let call = capture ~camera:camera_1 ~microphone:microphone_1 ~size:(600.0, 400.0) ~frame_rate:30.0 () in
        let missing = capture ~camera:"no-such-camera" () in
        let self_view = ref None in
        let root =
          column
            [
              label ~bind:labels.(0); (* label#0 *)
              label ~bind:labels.(1);
              label ~bind:labels.(2);
              label ~bind:labels.(3);
              label ~bind:labels.(4); (* label#4 *)
              row ~wrap:true
                [
                  button ~text:"Ask camera" ~on_click:(fun () -> request_permission Capture_kind.Camera);
                  button ~text:"Start" ~on_click:(fun () -> start_capture call);
                  button ~text:"Switch" ~on_click:(fun () ->
                      capture_camera call (Some camera_2);
                      capture_microphone call (Some microphone_2);
                      capture_size call 1280.0 720.0;
                      capture_frame_rate call 15.0);
                  button ~text:"Mute" ~on_click:(fun () -> capture_muted call true);
                  button ~text:"Camera off" ~on_click:(fun () -> capture_camera call None);
                  button ~text:"Stop" ~on_click:(fun () -> stop_capture call);
                  button ~text:"Open missing" ~on_click:(fun () -> start_capture missing); (* button#6 *)
                  button ~text:"Wide cover" ~on_click:(fun () ->
                      set_aspect (Option.get !self_view) 16 9;
                      set_fit (Option.get !self_view) Fit.Cover);
                  button ~text:"Wide contain" ~on_click:(fun () -> set_fit (Option.get !self_view) Fit.Contain); (* button#8 *)
                ];
              (fun () ->
                let w = video_capture ~a11y_label:"Self view" ~capture:call () in (* video#0 *)
                self_view := Some w;
                w);
            ]
            ()
        in
        mount root;
        watch_capture_devices true;
        (labels, call, missing))
  in
  on_capture_devices app (fun devices -> write labels.(0) (String.concat "; " (List.map device_line devices)));
  on_permission app (fun _ _ ->
      let p kind = Permission.name (permission app kind) in
      write labels.(1) (Printf.sprintf "camera %s, microphone %s" (p Capture_kind.Camera) (p Capture_kind.Microphone)));
  on_capture_state app call (fun r -> write labels.(2) (state_line r));
  on_capture_state app missing (fun r -> write labels.(4) (state_line r));

  (* The app's own code on kaya's capture thread: it checks what it was
     handed and posts what it saw, as a call's encoder would read it. *)
  let seen = ref (None, None) and seen_lock = Mutex.create () in
  let shown = labels.(3) in
  on_capture_frame app call (fun f ->
      let whole =
        Bytes.length f.y >= f.y_stride * f.height
        && Bytes.length f.uv >= f.uv_stride * ((f.height + 1) / 2)
        && f.y_stride >= f.width && f.uv_stride >= f.width
      in
      let size = if whole then Some (f.width, f.height) else None in
      Mutex.protect seen_lock (fun () ->
          let frames, chunk = !seen in
          if frames <> size then begin
            seen := (size, chunk);
            let line = evidence size chunk in
            post app (fun () -> write shown line)
          end));
  let posted = Atomic.make false in
  on_capture_samples app call (fun chunk _at ->
      if not (Atomic.exchange posted true) then
        Mutex.protect seen_lock (fun () ->
            let frames, _ = !seen in
            let n = Some (Bigarray.Array1.dim chunk) in
            seen := (frames, n);
            let line = evidence frames n in
            post app (fun () -> write shown line)));
  exit (run app)
