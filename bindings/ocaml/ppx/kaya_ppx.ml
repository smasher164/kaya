(* [@@deriving kaya]: the record declaration is the schema.

   For

     type todo = { title : string; done_ : bool } [@@deriving kaya]

   this emits the descriptor and one typed field token per field:

     val todo_record : todo Kaya_app.record_type
     val todo_title : (todo, string) Kaya_app.field
     val todo_done_ : (todo, bool) Kaya_app.field

   — the schema, both conversions, and the indexes all derive from the
   one declaration, so none can drift (the same single-source move as
   record! in Rust and the dataclass reader in Python). Every field
   must be wire-typed (string, bool, int64, float); OCaml keeps
   handlers out of records by idiom, so there is no guest-only
   skipping. *)

open Ppxlib

type wire = Str | Bool | I64 | F64

let wire_of_core_type (ct : core_type) =
  match ct with
  | [%type: string] -> Some Str
  | [%type: bool] -> Some Bool
  | [%type: int64] -> Some I64
  | [%type: Int64.t] -> Some I64
  | [%type: float] -> Some F64
  | _ -> None

let tag_expr ~loc = function
  | Str -> [%expr Kaya_wire.value_str]
  | Bool -> [%expr Kaya_wire.value_bool]
  | I64 -> [%expr Kaya_wire.value_i64]
  | F64 -> [%expr Kaya_wire.value_f64]

let value_ctor = function
  | Str -> "Str"
  | Bool -> "Bool"
  | I64 -> "I64"
  | F64 -> "F64"

let field_ctor = function
  | Str -> "str_field"
  | Bool -> "bool_field"
  | I64 -> "i64_field"
  | F64 -> "f64_field"

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
                   or float)"
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
                      (Ast_builder.Default.pexp_field ~loc [%expr r]
                         (lident name))))
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
            (List.map (fun (name, _) -> (lident name, evar name)) fields)
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
      descriptor :: tokens
  | _ ->
      Location.raise_errorf ~loc
        "kaya: [@@deriving kaya] applies to a single record type"

let () =
  let impl = Deriving.Generator.V2.make_noarg generate in
  Deriving.add "kaya" ~str_type_decl:impl |> Deriving.ignore
