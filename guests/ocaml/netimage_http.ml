(* The network images scene over HTTP, OCaml port —
   guests/rust/netimage_http.rs, tools/scenes/netimage_http.steps: the row
   image helper fetching from the lane's media server with the app's own
   client, cohttp. *)

open Kaya_app

type track = { title : string; art_url : string; art : bytes; phase : Image_phase.t }
[@@deriving kaya_gen]

let covers = [| "covers/cover-600.jpg"; "covers/cover-320.jpg"; "covers/cover-1000.jpg" |]

(* Lwt's scheduler is one per process and not thread-safe, so one thread
   runs it and the helper's workers enter it through Lwt_preemptive. *)
let () =
  let never, _ = Lwt.wait () in
  ignore (Thread.create (fun () -> Lwt_main.run never) ())

let fetch url =
  Lwt_preemptive.run_in_main (fun () ->
      Lwt.catch
        (fun () ->
          let open Lwt.Syntax in
          let* response, body = Cohttp_lwt_unix.Client.get (Uri.of_string url) in
          let* bytes = Cohttp_lwt.Body.to_string body in
          match Cohttp.Code.code_of_status (Cohttp.Response.status response) with
          | code when code >= 200 && code < 300 -> Lwt.return (Ok (Bytes.of_string bytes))
          | code -> Lwt.return (Error (Printf.sprintf "%s: status code %d" url code)))
        (fun e -> Lwt.return (Error (Printexc.to_string e))))

let () =
  let base =
    match Sys.getenv_opt "KAYA_MEDIA_URL" with
    | Some base -> base
    | None ->
        failwith
          "kaya: the netimage_http scene reads KAYA_MEDIA_URL, the local server the lane \
           starts (tools/lib/media_server.py)"
  in
  let app = Kaya_app.create () in
  let failures = ref 0 in

  build app (fun () ->
      window ~title:"netimage_http" ~width:640.0 ~height:560.0 ();
      let errors = signal Scalar.Str "errors: 0" in
      let tracks = collection_of track_record in
      let art =
        Row_images.create app tracks ~url:track_art_url ~art:track_art ~phase:track_phase ~fetch
      in
      Row_images.on_error art (fun _ _ ->
          incr failures;
          write errors (Printf.sprintf "errors: %d" !failures));
      let table, _ =
        for_each (record_handle tracks)
          (fun () ->
            Tpl.(
              row
                [
                  image ~bind_field:track_art ~fit:Fit.Cover ~max_width:20.0 ~max_height:20.0
                    ~phase_field:track_phase ~a11y_id:"art"
                    ~on_needed:(Row_images.needed art) ~on_released:(Row_images.released art);
                  label ~bind_field:track_title;
                ]
                ()))
          ()
      in
      columns table [ "Art"; "Title" ] sort_none;
      set_grow table 1.0;
      mount (row [ label ~bind:errors ~a11y_id:"errors"; w table ] ());
      let loading title path =
        { title; art_url = base ^ "/" ^ path; art = Bytes.empty; phase = Image_phase.Loading }
      in
      List.iter
        (fun (key, path) -> insert_record tracks (Key.str key) (loading key path))
        [
          ("missing", "status/404/");
          ("broken", "status/500/");
          ("junk", "covers/README.md");
          ("slow", "trickle/covers/cover-600.jpg");
        ];
      for i = 0 to 11 do
        insert_record tracks
          (Key.str (Printf.sprintf "a%02d" i))
          (loading (Printf.sprintf "Track %d" i) covers.(i mod 3))
      done);

  exit (run app)
