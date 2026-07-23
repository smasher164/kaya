(* [@@deriving kaya_gen]: the record declaration is the schema.

   For

     type todo = { title : string; done_ : bool } [@@deriving kaya_gen]

   this emits the descriptor, one typed field token per field, and the
   patch function — typed field writes with the key spelled once, one
   optional labelled argument per field (Python's kwargs patch, but
   static):

     val todo_record : todo Kaya_app.record_type
     val todo_title : (todo, string) Kaya_app.field
     val todo_done_ : (todo, bool) Kaya_app.field
     val todo_patch :
       ?title:string -> ?done_:bool ->
       todo Kaya_app.record_collection -> Kaya_wire.value -> unit

   Each supplied argument records one update_field — a patch is
   recorded writes, never a diff. The schema, both conversions, the
   indexes, and the patch all derive from the one declaration, so none
   can drift (the same single-source move as #[derive(Kaya)] in Rust
   and the dataclass reader in Python). Every field must be wire-typed
   (string, bool, int64, float, or bytes — the blob kind: the model
   keeps the guest's own bytes, and every insert/update/update_field
   re-registers them with the core at encode time, because blob handles
   are single-submit); OCaml keeps handlers out of records by idiom, so
   there is no guest-only skipping.

   On a variant whose constructors carry inline records —

     type post = Note of { text : string }
               | Todo of { title : string; done_ : bool }
     [@@deriving kaya_gen]

   it derives the sum: the descriptor (post_sum), one typed field token
   per constructor field (post_note_text, post_todo_done_), one refined
   patch per constructor (post_todo_patch — its witnessed writes refuse
   an entry that no longer holds Todo), and the eliminator

     val post_each : post Kaya_app.sum_collection ->
       note:(unit -> 'a) -> todo:(unit -> 'a) ->
       unit -> Kaya_app.widget

   whose labelled arguments are required — template totality is a
   compile error here, and the scene checks it again. *)

open Ppxlib

type wire = Str | Bool | I64 | F64 | Blob

let wire_of_core_type (ct : core_type) =
  match ct with
  | [%type: string] -> Some Str
  | [%type: bool] -> Some Bool
  | [%type: int64] -> Some I64
  | [%type: Int64.t] -> Some I64
  | [%type: float] -> Some F64
  | [%type: bytes] -> Some Blob
  | [%type: Bytes.t] -> Some Blob
  | _ -> None

let tag_expr ~loc = function
  | Str -> [%expr Kaya_wire.value_str]
  | Bool -> [%expr Kaya_wire.value_bool]
  | I64 -> [%expr Kaya_wire.value_i64]
  | F64 -> [%expr Kaya_wire.value_f64]
  | Blob -> [%expr Kaya_wire.value_blob]

(* A blob field's MODEL value carries the guest's own bytes as a
   binary Str (the wire side re-registers them at encode time, in
   Kaya_app.encode_field — handles are single-submit), so its value
   constructor is Str, wrapped by the conversions below. *)
let value_ctor = function
  | Str -> "Str"
  | Bool -> "Bool"
  | I64 -> "I64"
  | F64 -> "F64"
  | Blob -> "Str"

(* Wrap a record field's read for its model value (bytes -> Str). *)
let to_model_expr ~loc w e =
  match w with Blob -> [%expr Bytes.to_string [%e e]] | _ -> e

(* Wrap a model value's bound variable back to the record field. *)
let of_model_expr ~loc w e =
  match w with Blob -> [%expr Bytes.of_string [%e e]] | _ -> e

let field_ctor = function
  | Str -> "str_field"
  | Bool -> "bool_field"
  | I64 -> "i64_field"
  | F64 -> "f64_field"
  | Blob -> "blob_field"

let generate ~ctxt (_rec_flag, type_decls) =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  match type_decls with
  | [ { ptype_name; ptype_kind = Ptype_record labels; _ } ] ->
      let tname = ptype_name.txt in
      let fields =
        List.map
          (fun ld ->
            match wire_of_core_type ld.pld_type with
            | Some w -> (ld.pld_name.txt, w)
            | None ->
                Location.raise_errorf ~loc:ld.pld_loc
                  "kaya: field %s is not wire-typed (string, bool, int64, \
                   float, or bytes)"
                  ld.pld_name.txt)
          labels
      in
      let evar name = Ast_builder.Default.evar ~loc name in
      let pvar name = Ast_builder.Default.pvar ~loc name in
      let lident name = { loc; txt = Lident name } in
      (* rt_schema = [tag; tag; ...] *)
      let schema =
        Ast_builder.Default.elist ~loc
          (List.map (fun (_, w) -> tag_expr ~loc w) fields)
      in
      (* rt_to_values = fun r -> [Str r.f1; Bool r.f2; ...] *)
      let to_values =
        let body =
          Ast_builder.Default.elist ~loc
            (List.map
               (fun (name, w) ->
                 Ast_builder.Default.econstruct
                   (Ast_builder.Default.constructor_declaration ~loc
                      ~name:{ loc; txt = value_ctor w }
                      ~args:(Pcstr_tuple []) ~res:None)
                   (Some
                      (to_model_expr ~loc w
                         (Ast_builder.Default.pexp_field ~loc [%expr r]
                            (lident name)))))
               fields)
        in
        [%expr fun r -> [%e body]]
      in
      (* rt_of_values = function [Str f1; Bool f2; ...] -> {f1; f2}
         | _ -> invalid_arg *)
      let of_values =
        let pattern =
          Ast_builder.Default.plist ~loc
            (List.map
               (fun (name, w) ->
                 Ast_builder.Default.ppat_construct ~loc
                   (lident (value_ctor w))
                   (Some (pvar name)))
               fields)
        in
        let record =
          Ast_builder.Default.pexp_record ~loc
            (List.map
               (fun (name, w) -> (lident name, of_model_expr ~loc w (evar name)))
               fields)
            None
        in
        [%expr
          function
          | [%p pattern] -> [%e record]
          | _ ->
              invalid_arg
                [%e
                  Ast_builder.Default.estring ~loc
                    ("kaya: " ^ tname ^ " fields out of order")]]
      in
      let descriptor =
        [%stri
          let [%p pvar (tname ^ "_record")] =
            {
              Kaya_app.rt_schema = [%e schema];
              rt_to_values = [%e to_values];
              rt_of_values = [%e of_values];
            }]
      in
      let tokens =
        List.mapi
          (fun i (name, w) ->
            [%stri
              let [%p pvar (tname ^ "_" ^ name)] =
                [%e evar ("Kaya_app." ^ field_ctor w)]
                  [%e Ast_builder.Default.eint ~loc i]])
          fields
      in
      (* <t>_patch ?f1 ?f2 rc key: each supplied argument is one
         update_field. Internal names carry the __kaya_ prefix so a
         field named rc/key/tx cannot capture them. *)
      let patch =
        let write_one (name, _) =
          [%expr
            match [%e evar name] with
            | Some __kaya_v ->
                Kaya_app.update_field __kaya_rc __kaya_key
                  [%e evar (tname ^ "_" ^ name)]
                  __kaya_v
            | None -> ()]
        in
        let body =
          match List.map write_one fields with
          | [] -> assert false
          | first :: rest ->
              List.fold_left
                (fun acc e -> Ast_builder.Default.pexp_sequence ~loc acc e)
                first rest
        in
        let inner = [%expr fun __kaya_rc __kaya_key -> [%e body]] in
        let with_optionals =
          List.fold_right
            (fun (name, _) acc ->
              Ast_builder.Default.pexp_fun ~loc (Optional name) None (pvar name) acc)
            fields inner
        in
        [%stri let [%p pvar (tname ^ "_patch")] = [%e with_optionals]]
      in
      (descriptor :: tokens) @ [ patch ]
  | [ { ptype_name; ptype_kind = Ptype_variant ctors; _ } ] ->
      let tname = ptype_name.txt in
      let evar name = Ast_builder.Default.evar ~loc name in
      let pvar name = Ast_builder.Default.pvar ~loc name in
      let lident name = { loc; txt = Lident name } in
      let variants =
        List.map
          (fun cd ->
            match cd.pcd_args with
            | Pcstr_record labels ->
                let fields =
                  List.map
                    (fun ld ->
                      match wire_of_core_type ld.pld_type with
                      | Some w -> (ld.pld_name.txt, w)
                      | None ->
                          Location.raise_errorf ~loc:ld.pld_loc
                            "kaya: field %s is not wire-typed (string, bool, \
                             int64, float, or bytes)"
                            ld.pld_name.txt)
                    labels
                in
                (cd.pcd_name.txt, fields)
            | _ ->
                Location.raise_errorf ~loc:cd.pcd_loc
                  "kaya: constructor %s must carry an inline record \
                   (Note of { text : string })"
                  cd.pcd_name.txt)
          ctors
      in
      let arm_label ctor = String.lowercase_ascii ctor in
      (* st_schemas = [[tags]; [tags]; ...] *)
      let schemas =
        Ast_builder.Default.elist ~loc
          (List.map
             (fun (_, fields) ->
               Ast_builder.Default.elist ~loc
                 (List.map (fun (_, w) -> tag_expr ~loc w) fields))
             variants)
      in
      (* st_variant = function Note _ -> 0 | Todo _ -> 1 *)
      let variant_fn =
        let cases =
          List.mapi
            (fun i (ctor, _) ->
              Ast_builder.Default.case
                ~lhs:
                  (Ast_builder.Default.ppat_construct ~loc (lident ctor)
                     (Some (Ast_builder.Default.ppat_any ~loc)))
                ~guard:None
                ~rhs:(Ast_builder.Default.eint ~loc i))
            variants
        in
        [%expr
          fun __kaya_x ->
            [%e Ast_builder.Default.pexp_match ~loc [%expr __kaya_x] cases]]
      in
      (* st_to_values = function Note r -> [Str r.text] | ... *)
      let to_values_fn =
        let cases =
          List.map
             (fun (ctor, fields) ->
               Ast_builder.Default.case
                 ~lhs:
                   (Ast_builder.Default.ppat_construct ~loc (lident ctor)
                      (Some (pvar "__kaya_r")))
                 ~guard:None
                 ~rhs:
                   (Ast_builder.Default.elist ~loc
                      (List.map
                         (fun (name, w) ->
                           Ast_builder.Default.econstruct
                             (Ast_builder.Default.constructor_declaration ~loc
                                ~name:{ loc; txt = value_ctor w }
                                ~args:(Pcstr_tuple []) ~res:None)
                             (Some
                                (to_model_expr ~loc w
                                   (Ast_builder.Default.pexp_field ~loc
                                      [%expr __kaya_r] (lident name)))))
                         fields)))
             variants
        in
        [%expr
          fun __kaya_x ->
            [%e Ast_builder.Default.pexp_match ~loc [%expr __kaya_x] cases]]
      in
      (* st_of_values = fun variant values -> match (variant, values)
         with (0, [Str text]) -> Note { text } | ... *)
      let of_values_fn =
        let cases =
          List.mapi
            (fun i (ctor, fields) ->
              let values_pattern =
                Ast_builder.Default.plist ~loc
                  (List.map
                     (fun (name, w) ->
                       Ast_builder.Default.ppat_construct ~loc
                         (lident (value_ctor w))
                         (Some (pvar name)))
                     fields)
              in
              let record =
                Ast_builder.Default.pexp_record ~loc
                  (List.map
                     (fun (name, w) ->
                       (lident name, of_model_expr ~loc w (evar name)))
                     fields)
                  None
              in
              Ast_builder.Default.case
                ~lhs:
                  (Ast_builder.Default.ppat_tuple ~loc
                     [ Ast_builder.Default.pint ~loc i; values_pattern ])
                ~guard:None
                ~rhs:
                  (Ast_builder.Default.pexp_construct ~loc (lident ctor)
                     (Some record)))
            variants
        in
        let fallback =
          Ast_builder.Default.case
            ~lhs:(Ast_builder.Default.ppat_any ~loc)
            ~guard:None
            ~rhs:
              [%expr
                invalid_arg
                  [%e
                    Ast_builder.Default.estring ~loc
                      ("kaya: " ^ tname ^ " variant out of shape")]]
        in
        [%expr
          fun __kaya_variant __kaya_values ->
            [%e
              Ast_builder.Default.pexp_match ~loc
                [%expr (__kaya_variant, __kaya_values)]
                (cases @ [ fallback ])]]
      in
      let descriptor =
        [%stri
          let [%p pvar (tname ^ "_sum")] =
            {
              Kaya_app.st_schemas = [%e schemas];
              st_variant = [%e variant_fn];
              st_to_values = [%e to_values_fn];
              st_of_values = [%e of_values_fn];
            }]
      in
      (* Field tokens per constructor: post_note_text = str_field 0. *)
      let tokens =
        List.concat_map
          (fun (ctor, fields) ->
            List.mapi
              (fun i (name, w) ->
                [%stri
                  let [%p pvar (tname ^ "_" ^ arm_label ctor ^ "_" ^ name)] =
                    [%e evar ("Kaya_app." ^ field_ctor w)]
                      [%e Ast_builder.Default.eint ~loc i]])
              fields)
          variants
      in
      (* Refined patches per constructor: post_todo_patch ?title
         ?done_ sc key — each supplied argument is one witnessed
         update_field, and the model refuses a drifted entry. *)
      let patches =
        List.mapi
          (fun vi (ctor, fields) ->
            let write_one (name, _) =
              [%expr
                match [%e evar name] with
                | Some __kaya_v ->
                    Kaya_app.sum_update_field __kaya_sc __kaya_key
                      ~variant:[%e Ast_builder.Default.eint ~loc vi]
                      [%e evar (tname ^ "_" ^ arm_label ctor ^ "_" ^ name)]
                      __kaya_v
                | None -> ()]
            in
            let body =
              match List.map write_one fields with
              | [] -> [%expr ()]
              | first :: rest ->
                  List.fold_left
                    (fun acc e -> Ast_builder.Default.pexp_sequence ~loc acc e)
                    first rest
            in
            let inner =
              [%expr fun __kaya_sc __kaya_key -> [%e body]]
            in
            let with_optionals =
              List.fold_right
                (fun (name, _) acc ->
                  Ast_builder.Default.pexp_fun ~loc (Optional name) None
                    (pvar name) acc)
                fields inner
            in
            [%stri
              let [%p pvar (tname ^ "_" ^ arm_label ctor ^ "_patch")] =
                [%e with_optionals]])
          variants
      in
      (* The eliminator: required labelled arms, one per constructor —
         totality is a compile error at every use site. *)
      let eliminator =
        let arms =
          Ast_builder.Default.elist ~loc
            (List.mapi
               (fun i (ctor, _) ->
                 Ast_builder.Default.pexp_tuple ~loc
                   [
                     Ast_builder.Default.eint ~loc i;
                     evar (arm_label ctor);
                   ])
               variants)
        in
        let inner =
          [%expr fun __kaya_sc -> Kaya_app.each_sum __kaya_sc [%e arms]]
        in
        let with_labels =
          List.fold_right
            (fun (ctor, _) acc ->
              Ast_builder.Default.pexp_fun ~loc
                (Labelled (arm_label ctor))
                None
                (pvar (arm_label ctor))
                acc)
            variants
            [%expr fun __kaya_sc -> Kaya_app.each_sum __kaya_sc [%e arms]]
        in
        ignore inner;
        [%stri let [%p pvar (tname ^ "_each")] = [%e with_labels]]
      in
      (descriptor :: tokens) @ patches @ [ eliminator ]
  | _ ->
      Location.raise_errorf ~loc
        "kaya: [@@deriving kaya_gen] applies to a single record type"

let () =
  let impl = Deriving.Generator.V2.make_noarg generate in
  Deriving.add "kaya_gen" ~str_type_decl:impl |> Deriving.ignore
