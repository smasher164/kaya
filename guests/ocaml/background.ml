(* The background conformance scene, OCaml port — work off the app
   thread, posted back (docs/background-work-plan.md).

   THE ODD SHAPE IS SO THAT A WRONG IMPLEMENTATION DEADLOCKS RATHER
   THAN DISAGREES: the worker parks until a CLICK releases it, and only
   a live app thread can process a click. The accumulators need no lock
   — everything touching them runs on the app thread. *)

open Kaya_wire
open Kaya_app

let release_lock = Mutex.create ()
let release_cond = Condition.create ()
let released = ref false
let posted = ref ""
let nested = ref ""

let () =
  let app = Kaya_app.create () in

  build app (fun () ->
      window ~title:"background" ();
      let status = signal (Str "idle") in
      let alive = signal (Str "-") in
      let detail = signal (Str "-") in

      let start () =
        let worker () =
          (* Parks until the scene clicks release: on the app thread
             that click could never be processed. *)
          Mutex.lock release_lock;
          while not !released do
            Condition.wait release_cond release_lock
          done;
          Mutex.unlock release_lock;
          (* Three posts, in order. The accumulator makes this a test of
             ORDER, not of which one ran last. *)
          List.iter
            (fun step ->
              post app (fun () ->
                  posted := !posted ^ step;
                  write status (Str !posted)))
            [ "1"; "2"; "3" ]
        in
        ignore (Thread.create worker ());
        write status (Str "working")
      in
      let ping () = write alive (Str "alive") in
      (* THIS RELEASE TAKES A LOCK ON THE APP THREAD, unlike every other
         guest's: OCaml's stdlib has no lock-free latch the way the
         others do (close, Event.set, semaphore.signal, countDown). It is
         bounded — the worker holds release_lock only to test the
         predicate, and Condition.wait releases it while parked. *)
      let release () =
        Mutex.lock release_lock;
        released := true;
        Condition.broadcast release_cond;
        Mutex.unlock release_lock
      in
      (* A post from INSIDE a handler QUEUES for after; it never nests.
         So this commits "ac" and the posted thunk then commits "acb";
         nesting could only ever produce "abc". *)
      let nest () =
        nested := !nested ^ "a";
        post app (fun () ->
            nested := !nested ^ "b";
            write detail (Str !nested));
        nested := !nested ^ "c";
        write detail (Str !nested)
      in

      (* Children are THUNKS: omitting the trailing unit leaves one, and
         the container realizes them left to right (DESIGN.md, Binding
         conventions). *)
      let root =
        column
          [
            label ~a11y_id:"status" ~bind:status (* label#0 *);
            label ~a11y_id:"alive" ~bind:alive (* label#1 *);
            (* Authored because the closing AX read needs an identifier;
               an index read passes for an arm that drew nothing. *)
            label ~a11y_id:"nested" ~bind:detail (* label#2 *);
            button ~text:"start" ~on_click:start (* button#0 *);
            button ~text:"ping" ~on_click:ping (* button#1 *);
            button ~text:"release" ~on_click:release (* button#2 *);
            button ~text:"nest" ~on_click:nest (* button#3 *);
          ]
          ()
      in
      mount root);

  exit (run app)
