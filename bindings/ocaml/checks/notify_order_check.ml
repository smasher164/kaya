(* The process-level notification handler's DISPATCH ORDER
   (docs/tasks-s9-plan.md R1), run rather than read. A tap on a reminder
   after the app has exited relaunches the process, and THAT process never
   called show, so the one-shot table is empty for the id that started it.
   The ring loop's branch has no seam a test can reach — the ring is C
   memory — so these drive [Kaya_app.notification_result], which the
   branch calls and tools/check-sugar-surface.py holds it to calling.
   Headless: the library loads (KAYA_LIB) but the core loop is never
   entered. *)

open Kaya_app

let fail fmt =
  Printf.ksprintf
    (fun msg ->
      print_endline ("notify-order: FAIL — " ^ msg);
      exit 1)
    fmt

let check ok what = if not ok then fail "%s" what

let () =
  let app = create () in
  let one_shot = ref [] in
  let process = ref [] in
  on_notification_activation app ~f:(fun id outcome ->
      process := !process @ [ (id, outcome) ]);
  build app (fun () ->
      ignore
        (show_notification ~title:"bound at the show"
           ~on_result:(fun outcome -> one_shot := !one_shot @ [ outcome ])
           12L));

  (* CASE 1: an id WITH a one-shot handler is answered by it, and the
     process-level handler is not consulted at all. *)
  notification_result app 12L Kaya_wire.notification_outcome_activated;
  check
    (!one_shot = [ Kaya_wire.notification_outcome_activated ])
    "the one-shot handler did not answer";
  check (!process = [])
    "the process-level handler answered an id that HAD a one-shot handler";

  (* CASE 2: an id this process never showed — the relaunch case. *)
  notification_result app 77L Kaya_wire.notification_outcome_activated;
  check
    (!process = [ (77L, Kaya_wire.notification_outcome_activated) ])
    "a result with no one-shot handler did not reach the process-level one";

  (* CASE 3: it does NOT retire. *)
  notification_result app 78L Kaya_wire.notification_outcome_refused;
  check
    (List.length !process = 2
    && List.nth !process 1 = (78L, Kaya_wire.notification_outcome_refused))
    "the process-level handler retired after its first result";

  (* AND THE DROP IS ANNOUNCED, compared in full: a drop nobody announced
     is R5's defect class, and this sentence is the only signal a
     relaunched process's author gets that nothing listened. stderr is a
     real fd, so it is redirected to a temp file and read back. *)
  let bare = create () in
  let path = Filename.temp_file "kaya-notify" ".txt" in
  let saved = Unix.dup Unix.stderr in
  let out = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 out Unix.stderr;
  Unix.close out;
  notification_result bare 41L Kaya_wire.notification_outcome_refused;
  flush stderr;
  Unix.dup2 saved Unix.stderr;
  Unix.close saved;
  let ic = open_in path in
  let said = In_channel.input_all ic in
  close_in ic;
  Sys.remove path;
  let want =
    "kaya: notification 41 outcome refused reached no handler — none was \
     bound at the show and no process-level handler is registered \
     (Kaya_app.on_notification_activation)"
  in
  check
    (String.trim said = want)
    (Printf.sprintf "the drop was announced as %S, wanted %S"
       (String.trim said) want);

  print_endline
    "notify-order: OK — the one-shot wins, an unknown id reaches the \
     process handler, it does not retire, and an unclaimed result \
     announces its drop"

(* THE APP-LINK ROUTES (docs/app-links-plan.md §4), run rather than read.
   Four things no lane can see: the declaration's BYTES, the ids the
   counter mints, the dispatch by route id, and the two drops — a route
   that matched and reached no handler says so, route 0 says nothing
   because the CORE already announced that miss naming every declared
   pattern. NOTHING HERE READS A PATTERN: the core is the one parser and
   the one author of every declaration refusal, and it faults at apply. *)
let () =
  let app = create () in
  let seen = ref [] in
  link app ~pattern:"task/{key}" ~f:(fun params -> seen := !seen @ [ ("task", params) ]);
  link app ~pattern:"{section}" ~f:(fun params -> seen := !seen @ [ ("section", params) ]);

  (* CASE 1: the declaration is the generated record, parked, and the ids
     come from the binding's own counter starting at 1. *)
  check
    (app.pending_routes
    = [
        Kaya_wire.tx_declare_link_route 1L (Kaya_wire.Str "task/{key}");
        Kaya_wire.tx_declare_link_route 2L (Kaya_wire.Str "{section}");
      ])
    "link did not park the generated records, or minted the wrong ids";

  (* CASE 2: a link on a declared route reaches its handler with the
     captures, and the registration does NOT retire. *)
  link_opened app 1L "dev.kaya.aurora.notes://task/t2" [ ("key", "t2") ];
  link_opened app 1L "dev.kaya.aurora.notes://task/t1" [ ("key", "t1") ];
  link_opened app 2L "dev.kaya.aurora.notes://today" [ ("section", "today") ];
  check
    (!seen
    = [
        ("task", [ ("key", "t2") ]);
        ("task", [ ("key", "t1") ]);
        ("section", [ ("section", "today") ]);
      ])
    "a link did not reach its route's handler with the captures, or the \
     registration retired";

  (* CASE 3 and CASE 4: the two drops, read off a real fd. *)
  let path = Filename.temp_file "kaya-link" ".txt" in
  let saved = Unix.dup Unix.stderr in
  let out = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 out Unix.stderr;
  Unix.close out;
  link_opened app 9L "dev.kaya.aurora.notes://task/t2" [ ("key", "t2") ];
  link_opened app 0L "dev.kaya.aurora.notes://nope" [];
  flush stderr;
  Unix.dup2 saved Unix.stderr;
  Unix.close saved;
  let ic = open_in path in
  let said = In_channel.input_all ic in
  close_in ic;
  Sys.remove path;
  check (List.length !seen = 3)
    "a route this process never declared reached a handler";
  let want =
    "kaya: link dev.kaya.aurora.notes://task/t2 matched route 9 and reached \
     no handler — none is registered for it (Kaya_app.link)"
  in
  check
    (String.trim said = want)
    (Printf.sprintf "the link drop was announced as %S, wanted %S"
       (String.trim said) want);

  print_endline
    "link-route: OK — the declaration parks the generated record, the \
     dispatch is by route id and does not retire, an unknown route \
     announces its drop, and route 0 is silent"
