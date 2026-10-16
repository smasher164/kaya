(* docs/traps.md, "An OCaml guest naming a sibling guest's module runs that guest". *)

let floor = 40

let module_of path = String.capitalize_ascii (Filename.remove_extension (Filename.basename path))

let is_guest path =
  Filename.check_suffix path ".ml"
  && not (Filename.check_suffix (Filename.remove_extension path) ".pp")

let () =
  match Array.to_list Sys.argv with
  | _ :: ocamldep :: files ->
      let files = List.filter is_guest files in
      let n = List.length files in
      if n < floor then (
        Printf.eprintf
          "kaya: guest isolation read %d guest sources, under its floor of %d; the rule's \
           deps no longer reach guests/ocaml/*.ml\n"
          n floor;
        exit 1);
      let guests = List.map module_of files in
      let ic = Unix.open_process_args_in ocamldep (Array.of_list (ocamldep :: "-modules" :: files)) in
      let findings = ref [] in
      (try
         while true do
           let line = input_line ic in
           match String.index_opt line ':' with
           | None -> ()
           | Some i ->
               let file = String.sub line 0 i in
               let self = module_of file in
               let named =
                 String.split_on_char ' ' (String.sub line (i + 1) (String.length line - i - 1))
               in
               List.iter
                 (fun m ->
                   if m <> self && List.mem m guests then findings := (file, m) :: !findings)
                 named
         done
       with End_of_file -> ());
      (match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> ()
      | _ ->
          Printf.eprintf "kaya: guest isolation: %s -modules failed over %d guest sources\n"
            ocamldep n;
          exit 1);
      (match List.rev !findings with
      | [] -> Printf.printf "guest isolation: %d guests, none names another\n" n
      | found ->
          List.iter
            (fun (file, m) ->
              let exe = Filename.remove_extension (Filename.basename file) in
              Printf.eprintf
                "kaya: guests/ocaml/%s names the module %s, which is also the guest %s.ml in \
                 this stanza: dune links that guest into %s.exe and ITS top level runs in place \
                 of this one, so the leg runs the wrong scene. Spell the module by a path that does \
                 not start with %s: Kaya_app.%s for the binding's, Stdlib.%s for the standard \
                 library's (docs/traps.md).\n"
                (Filename.basename file) m (String.uncapitalize_ascii m) exe m m m)
            found;
          exit 1)
  | _ ->
      prerr_endline "usage: guest_isolation OCAMLDEP GUEST.ml...";
      exit 2
