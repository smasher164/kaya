(* The far end, OCaml port — guests/rust/farend.rs, tools/scenes/farend.steps,
   docs/capture-plan.md §5: a surface showing the NV12 frames the app submits
   from its own thread, and a voice output playing the samples it writes. *)

open Kaya_app

(* A flat colour as NV12, video-range BT.601. *)
let nv12 w h rgb =
  let r = float_of_int ((rgb lsr 16) land 0xFF)
  and g = float_of_int ((rgb lsr 8) land 0xFF)
  and b = float_of_int (rgb land 0xFF) in
  let y = Float.to_int (Float.round (16.0 +. (0.257 *. r) +. (0.504 *. g) +. (0.098 *. b)))
  and u = Float.to_int (Float.round (128.0 -. (0.148 *. r) -. (0.291 *. g) +. (0.439 *. b)))
  and v = Float.to_int (Float.round (128.0 +. (0.439 *. r) -. (0.368 *. g) -. (0.071 *. b))) in
  let luma = Bytes.make (w * h) (Char.chr y) in
  let chroma = Bytes.create (w * h / 2) in
  for i = 0 to (w * h / 4) - 1 do
    Bytes.set chroma (2 * i) (Char.chr u);
    Bytes.set chroma ((2 * i) + 1) (Char.chr v)
  done;
  (luma, chroma)

(* What the far end sends: a flat colour at a size and a tone (0: silence). *)
type sends = { rgb : int; w : int; h : int; hz : float; on : bool }

(* The peer's thread: a frame every 1/15 s and 10 ms of samples every 10 ms,
   paced by the clock, until hung up. *)
let run_peer lock (peer : sends ref) surface voice =
  let start = Unix.gettimeofday () in
  let sent_frames = ref 0 and sent_samples = ref 0 in
  let shown = ref None in
  let phase = ref 0.0 in
  let chunk = Bigarray.Array1.create Bigarray.int16_signed Bigarray.c_layout 480 in
  let rec loop () =
    let now = Mutex.protect lock (fun () -> !peer) in
    if now.on then begin
      let elapsed = Unix.gettimeofday () -. start in
      while float_of_int !sent_frames /. 15.0 <= elapsed do
        let y, uv =
          match !shown with
          | Some (key, y, uv) when key = (now.rgb, now.w, now.h) -> (y, uv)
          | _ ->
              let y, uv = nv12 now.w now.h now.rgb in
              shown := Some ((now.rgb, now.w, now.h), y, uv);
              (y, uv)
        in
        ignore
          (surface_submit surface
             {
               Capture_frame.width = now.w;
               height = now.h;
               y;
               uv;
               y_stride = now.w;
               uv_stride = now.w;
               timestamp_ns = Int64.of_float (elapsed *. 1e9);
               rotation = 0;
             });
        incr sent_frames
      done;
      while float_of_int !sent_samples /. 48000.0 <= elapsed do
        for i = 0 to 479 do
          chunk.{i} <- (if now.hz > 0.0 then Float.to_int (sin !phase *. 12000.0) else 0);
          phase := Float.rem (!phase +. (2.0 *. Float.pi *. now.hz /. 48000.0)) (2.0 *. Float.pi)
        done;
        ignore (voice_write voice chunk);
        sent_samples := !sent_samples + 480
      done;
      Thread.delay 0.005;
      loop ()
    end
  in
  loop ()

let () =
  let app = create () in
  let lock = Mutex.create () in
  let peer = ref { rgb = 0x1E5AC8; w = 640; h = 480; hz = 660.0; on = false } in
  let call = ref None in
  let peer_view = ref None in
  let route =
    build app (fun () ->
        window ~title:"far end" ~width:520.0 ~height:640.0 ();
        let route = signal Scalar.Str "voice none" in
        let root =
          column
            [
              label ~bind:route; (* label#0 *)
              row
                [
                  button ~text:"Connect" ~on_click:(fun () ->
                      if Option.is_none !call then begin
                        let v =
                          voice
                            ~on_route:(fun r _ ->
                              write route
                                (match r with
                                | Voice_route.Voice | Voice_route.Plain | Voice_route.Synthetic -> "voice playing"
                                | Voice_route.Failed -> "voice failed"
                                | Voice_route.None -> "voice none"))
                            ()
                        in
                        Mutex.protect lock (fun () ->
                            peer := { rgb = 0x1E5AC8; w = 640; h = 480; hz = 660.0; on = true });
                        let thread = Thread.create (fun () -> run_peer lock peer (Option.get !peer_view) v) () in
                        call := Some (v, thread)
                      end);
                  button ~text:"Change" ~on_click:(fun () ->
                      Mutex.protect lock (fun () -> peer := { !peer with rgb = 0xC83C1E; w = 1280; h = 720; hz = 440.0 }));
                  button ~text:"Quiet" ~on_click:(fun () -> Mutex.protect lock (fun () -> peer := { !peer with hz = 0.0 }));
                  button ~text:"Hang up" ~on_click:(fun () ->
                      match !call with
                      | None -> ()
                      | Some (v, thread) ->
                          Mutex.protect lock (fun () -> peer := { !peer with on = false });
                          Thread.join thread;
                          release_voice v;
                          call := None;
                          write route "voice none"); (* button#3 *)
                ];
              (fun () ->
                let w = surface ~a11y_label:"Peer" () in (* surface#0 *)
                peer_view := Some w;
                w);
            ]
            ()
        in
        mount root;
        route)
  in
  ignore route;
  exit (run app)
