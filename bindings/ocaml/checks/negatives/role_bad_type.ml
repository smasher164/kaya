(* F4 negative: a menu item's ~role is a closed Menu_role.t variant, so
   a bare string is refused at compile time rather than reaching the
   core's runtime MENU_ROLES check. Run by ../negatives.py. *)
open Kaya_app

let () =
  let i = item ~role:"cut" ~label:"Cut" () in
  ignore i
