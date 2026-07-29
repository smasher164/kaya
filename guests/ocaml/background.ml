(* The background conformance scene, OCaml port — work off the app
   thread, posted back (docs/background-work-plan.md).

   WHAT IT PROVES, and the reason for its odd shape: a wrong
   implementation must DEADLOCK rather than disagree. The worker parks
   until a CLICK releases it, and only a live app thread can process a
   click — so a binding that let background work occupy the app thread
   cannot reach the end of the script at all. It could not even deliver
   its own release.

   The parking is a plain Mutex + Condition and the worker a plain
   Thread. kaya supplies no waiting primitive and should not: the point
   is that a guest uses its own language's concurrency and hands back
   only the result.

   The accumulators are the guest's own state rather than signal
   read-backs — signals are write-only by doctrine. They need no lock:
   everything that touches them runs on the app thread, inside a posted
   transaction. *)

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
          (* Parks here until the scene clicks release. Were the binding
             running this on the app thread, that click could never be
             processed and the whole scene would deadlock — the point. *)
          Mutex.lock release_lock;
          while not !released do
            Condition.wait release_cond release_lock
          done;
          Mutex.unlock release_lock;
          (* Three posts, in order. The accumulator makes this a test of
             ORDER and not merely of which one ran last. *)
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
      (* Proof the app thread is still serving input while the worker is
         parked and has posted nothing. *)
      let ping () = write alive (Str "alive") in
      (* This one takes a lock, unlike every other guest's release. It
         is bounded and safe — the worker only ever holds release_lock
         to test the predicate, and Condition.wait releases it while
         parked — but it IS a lock acquisition on the app thread, which
         is the kind of thing worth noticing rather than inheriting.
         OCaml has no lock-free latch in its stdlib the way the others
         do (close, Event.set, semaphore.signal, countDown). *)
      let release () =
        Mutex.lock release_lock;
        released := true;
        Condition.broadcast release_cond;
        Mutex.unlock release_lock
      in
      (* A post from INSIDE a handler QUEUES for after; it never nests.
         The handler appends a, posts a thunk appending b, appends c — so
         it commits "ac" and the posted thunk then commits "acb".
         Nesting can only ever produce "abc". *)
      let nest () =
        nested := !nested ^ "a";
        post app (fun () ->
            nested := !nested ^ "b";
            write detail (Str !nested));
        nested := !nested ^ "c";
        write detail (Str !nested)
      in

      (* Children are THUNKS: omitting the trailing unit leaves one, and
         the container realizes them left to right (the curried-children
         convention; DESIGN.md, Binding conventions). *)
      let root =
        column
          [
            label ~a11y_id:"status" ~bind:status (* label#0 *);
            label ~a11y_id:"alive" ~bind:alive (* label#1 *);
            (* Authored so the CLOSING read can address it: the AX read
               needs an identifier, and an index read passes for an arm
               that ran and drew nothing. *)
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
