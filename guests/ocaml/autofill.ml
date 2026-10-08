(* The content type scene, OCaml port — guests/rust/autofill.rs,
   tools/scenes/autofill.steps (docs/autofill-plan.md §5): a sign-in form,
   a sign-up form, a code field and a phone field, each saying what it
   holds; a button that turns the sign-in name into an email address and
   back; and a stamped code field. *)

open Kaya_app

type account = { name : string } [@@deriving kaya_gen]

let () =
  let app = Kaya_app.create () in
  let email = ref false in

  build app (fun () ->
      let accounts = collection_of account_record in
      let mode = signal Scalar.Str "sign in with a username" in

      let user =
        entry ~placeholder:"Username" ~content_type:Content_type.Username
          ~a11y_id:"user" ()
      in
      let root =
        column
          [
            w user;
            secure_field ~placeholder:"Password"
              ~content_type:Content_type.Password ~a11y_id:"password";
            label ~bind:mode ~a11y_id:"mode";
            button ~text:"Use email" ~a11y_id:"switch" ~on_click:(fun () ->
                email := not !email;
                if !email then begin
                  set_content_type user Content_type.Email;
                  write mode "sign in with an email address"
                end
                else begin
                  set_content_type user Content_type.Username;
                  write mode "sign in with a username"
                end);
            entry ~placeholder:"Email" ~content_type:Content_type.Email
              ~a11y_id:"email";
            secure_field ~placeholder:"New password"
              ~content_type:Content_type.New_password ~a11y_id:"new";
            entry ~placeholder:"Code"
              ~content_type:Content_type.One_time_code ~a11y_id:"code";
            entry ~placeholder:"Phone" ~content_type:Content_type.Phone
              ~a11y_id:"phone";
            entry ~placeholder:"Note" ~a11y_id:"note";
            each (record_handle accounts) (fun () ->
                Tpl.(
                  row
                    [
                      label ~bind_field:account_name;
                      secure_field ~content_type:Content_type.One_time_code
                        ~a11y_id:"pin";
                    ]
                    ()));
          ]
          ()
      in
      mount root;

      insert_record accounts (Key.str "a") { name = "a" });

  exit (run app)
