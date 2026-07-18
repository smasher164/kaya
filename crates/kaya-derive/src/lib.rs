//! `#[derive(Kaya)]`: the type's own shape is the schema. On a struct
//! it derives the one-variant sum (KayaSum + KayaRecord), field tokens,
//! and the typed patch builder — what the old `record!` macro emitted,
//! minus the wrapping. On an enum it derives the real sum: KayaSum with
//! one schema per constructor, case tokens for template elimination
//! (`Task::NOTE`), per-variant field tokens (`Task::note_text()`), and
//! per-variant patch handles reachable only through a match on the
//! model's current entry (`Task::note(tx, &items, key)` returns Option)
//! — so a field write on the wrong constructor is unrepresentable, and
//! a stale occurrence's arm simply doesn't run.

use proc_macro::TokenStream;
use proc_macro2::Span;
use quote::{format_ident, quote};
use syn::{Data, DeriveInput, Fields, Ident, parse_macro_input};

#[proc_macro_derive(Kaya)]
pub fn derive_kaya(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    match &input.data {
        Data::Struct(data) => derive_struct(&input, &data.fields),
        Data::Enum(data) => derive_enum(&input, data),
        Data::Union(_) => syn::Error::new(Span::call_site(), "kaya: a union is neither a record nor a sum")
            .to_compile_error()
            .into(),
    }
}

fn named_fields<'a>(
    fields: &'a Fields,
    what: &str,
) -> Result<Vec<(&'a Ident, &'a syn::Type)>, syn::Error> {
    match fields {
        Fields::Named(named) => Ok(named
            .named
            .iter()
            .map(|f| (f.ident.as_ref().unwrap(), &f.ty))
            .collect()),
        Fields::Unit => Ok(Vec::new()),
        Fields::Unnamed(_) => Err(syn::Error::new(
            Span::call_site(),
            format!("kaya: {what} needs named fields (or none) — indexes come from names the guest can see"),
        )),
    }
}

fn schema_of(fields: &[(&Ident, &syn::Type)]) -> proc_macro2::TokenStream {
    let types = fields.iter().map(|(_, ty)| {
        quote! { <<#ty as ::kaya::KayaField>::Kind as ::kaya::ValueKind>::TYPE }
    });
    quote! { &[#(#types),*] }
}

fn derive_struct(input: &DeriveInput, fields: &Fields) -> TokenStream {
    let name = &input.ident;
    let vis = &input.vis;
    let fields = match named_fields(fields, "a record struct") {
        Ok(f) => f,
        Err(e) => return e.to_compile_error().into(),
    };
    let schema = schema_of(&fields);
    let fnames: Vec<_> = fields.iter().map(|(n, _)| *n).collect();
    let ftypes: Vec<_> = fields.iter().map(|(_, t)| *t).collect();
    let indexes: Vec<u32> = (0..fields.len() as u32).collect();
    let patch = format_ident!("{name}Patch");

    quote! {
        impl ::kaya::KayaSum for #name {
            const VARIANTS: &'static [&'static [::kaya::ValueType]] = &[#schema];
            fn variant(&self) -> u32 { 0 }
            fn to_values(&self) -> Vec<::kaya::Value> {
                vec![#(::kaya::KayaField::to_value(&self.#fnames)),*]
            }
            fn from_parts(_variant: u32, values: &[::kaya::Value]) -> Self {
                Self { #(#fnames: <#ftypes as ::kaya::KayaField>::from_value(&values[#indexes as usize])),* }
            }
        }

        impl ::kaya::KayaRecord for #name {
            const SCHEMA: &'static [::kaya::ValueType] = <#name as ::kaya::KayaSum>::VARIANTS[0];
        }

        impl #name {
            #(
                pub fn #fnames() -> ::kaya::Field<<#ftypes as ::kaya::KayaField>::Kind> {
                    ::kaya::Field::new(#indexes)
                }
            )*
        }

        /// Typed field writes with the key spelled once; each setter
        /// records one update_field. A patch is recorded writes, never
        /// a diff — no clone, no comparison.
        #[allow(dead_code)]
        #vis struct #patch<'t, 'c> {
            tx: &'t mut ::kaya::Tx<'c>,
            instance: ::kaya::Collection<#name>,
            key: ::kaya::Value,
        }

        #[allow(dead_code)]
        impl<'t, 'c> #patch<'t, 'c> {
            #(
                pub fn #fnames(self, value: impl Into<#ftypes>) -> Self {
                    let Self { tx, instance, key } = self;
                    tx.update_field(&instance, key.clone(), #name::#fnames(), value.into());
                    Self { tx, instance, key }
                }
            )*
        }

        impl ::kaya::KayaPatch for #name {
            type Builder<'t, 'c> = #patch<'t, 'c> where 'c: 't;
            fn patch_builder<'t, 'c>(
                tx: &'t mut ::kaya::Tx<'c>,
                instance: &::kaya::Collection<#name>,
                key: ::kaya::Value,
            ) -> Self::Builder<'t, 'c> {
                #patch { tx, instance: instance.clone(), key }
            }
        }
    }
    .into()
}

fn derive_enum(input: &DeriveInput, data: &syn::DataEnum) -> TokenStream {
    let name = &input.ident;
    let vis = &input.vis;
    let mut variants = Vec::new();
    for v in &data.variants {
        let fields = match named_fields(&v.fields, "a sum constructor") {
            Ok(f) => f,
            Err(e) => return e.to_compile_error().into(),
        };
        variants.push((&v.ident, fields));
    }

    let schemas = variants.iter().map(|(_, fields)| schema_of(fields));

    let variant_arms = variants.iter().enumerate().map(|(i, (vname, fields))| {
        let i = i as u32;
        let pat = if fields.is_empty() {
            quote! { #name::#vname }
        } else {
            quote! { #name::#vname { .. } }
        };
        quote! { #pat => #i, }
    });

    let to_values_arms = variants.iter().map(|(vname, fields)| {
        let fnames: Vec<_> = fields.iter().map(|(n, _)| *n).collect();
        if fields.is_empty() {
            quote! { #name::#vname => Vec::new(), }
        } else {
            quote! {
                #name::#vname { #(#fnames),* } =>
                    vec![#(::kaya::KayaField::to_value(#fnames)),*],
            }
        }
    });

    let from_parts_arms = variants.iter().enumerate().map(|(i, (vname, fields))| {
        let i = i as u32;
        let inits = fields.iter().enumerate().map(|(at, (fname, fty))| {
            quote! { #fname: <#fty as ::kaya::KayaField>::from_value(&values[#at]) }
        });
        quote! { #i => #name::#vname { #(#inits),* }, }
    });

    // Per-variant field tokens (Task::note_text()) and the
    // match-refined accessors (Task::note(tx, &items, key) ->
    // Option<TaskNotePatch>).
    let mut tokens = Vec::new();
    let mut patches = Vec::new();
    for (i, (vname, fields)) in variants.iter().enumerate() {
        let i = i as u32;
        let snake = snake_case(&vname.to_string());
        let accessor = format_ident!("{snake}");
        let patch = format_ident!("{name}{vname}Patch");

        let field_tokens = fields.iter().enumerate().map(|(at, (fname, fty))| {
            let at = at as u32;
            let token = format_ident!("{snake}_{fname}");
            quote! {
                pub fn #token() -> ::kaya::Field<<#fty as ::kaya::KayaField>::Kind> {
                    ::kaya::Field::new(#at)
                }
            }
        });

        tokens.push(quote! {
            #(#field_tokens)*

            /// The match arm as an accessor: `Some` exactly when the
            /// entry currently holds this constructor, handing back a
            /// patch refined to its fields. A stale occurrence's arm
            /// simply doesn't run.
            pub fn #accessor<'t, 'c>(
                tx: &'t mut ::kaya::Tx<'c>,
                instance: &::kaya::Collection<#name>,
                key: impl Into<::kaya::Value>,
            ) -> Option<#patch<'t, 'c>> {
                let key = key.into();
                (tx.variant_of(instance, &key)? == #i)
                    .then(|| #patch { tx, instance: instance.clone(), key })
            }
        });

        let setters = fields.iter().enumerate().map(|(at, (fname, fty))| {
            let at = at as u32;
            quote! {
                pub fn #fname(self, value: impl Into<#fty>) -> Self {
                    let Self { tx, instance, key } = self;
                    let value: #fty = value.into();
                    tx.update_field_witnessed(
                        &instance,
                        key.clone(),
                        #i,
                        #at,
                        ::kaya::KayaField::to_value(&value),
                    );
                    Self { tx, instance, key }
                }
            }
        });

        patches.push(quote! {
            /// Field writes refined to one constructor, reachable only
            /// through the accessor's match; each setter records one
            /// update_field carrying the witnessed discriminant.
            #[allow(dead_code)]
            #vis struct #patch<'t, 'c> {
                tx: &'t mut ::kaya::Tx<'c>,
                instance: ::kaya::Collection<#name>,
                key: ::kaya::Value,
            }

            #[allow(dead_code)]
            impl<'t, 'c> #patch<'t, 'c> {
                #(#setters)*
            }
        });
    }

    // The template eliminator: a record of arms, one field per
    // constructor, so the struct literal is the totality check. Arm
    // returns ride out in the matching field of the Out record.
    let cases = format_ident!("{name}Cases");
    let cases_out = format_ident!("{name}CasesOut");
    let arm_names: Vec<_> = variants
        .iter()
        .map(|(vname, _)| format_ident!("{}", snake_case(&vname.to_string())))
        .collect();
    let arm_fn_params: Vec<_> = variants
        .iter()
        .map(|(vname, _)| format_ident!("F{vname}"))
        .collect();
    let arm_out_params: Vec<_> = variants
        .iter()
        .map(|(vname, _)| format_ident!("R{vname}"))
        .collect();
    let arm_indexes: Vec<u32> = (0..variants.len() as u32).collect();

    quote! {
        impl ::kaya::KayaSum for #name {
            const VARIANTS: &'static [&'static [::kaya::ValueType]] = &[#(#schemas),*];
            fn variant(&self) -> u32 {
                match self { #(#variant_arms)* }
            }
            fn to_values(&self) -> Vec<::kaya::Value> {
                match self { #(#to_values_arms)* }
            }
            fn from_parts(variant: u32, values: &[::kaya::Value]) -> Self {
                match variant {
                    #(#from_parts_arms)*
                    other => panic!("kaya: {} has no variant {other}", stringify!(#name)),
                }
            }
        }

        /// The eliminator as a record of arms: one field per
        /// constructor, held total by the struct literal itself.
        /// `|_| {}` is the explicit empty arm.
        #[allow(dead_code)]
        #vis struct #cases<#(#arm_fn_params),*> {
            #(pub #arm_names: #arm_fn_params),*
        }

        /// What the arms returned, by constructor name.
        #[allow(dead_code)]
        #vis struct #cases_out<#(#arm_out_params),*> {
            #(pub #arm_names: #arm_out_params),*
        }

        impl<#(#arm_fn_params, #arm_out_params),*> ::kaya::KayaCases<#name>
            for #cases<#(#arm_fn_params),*>
        where
            #(#arm_fn_params: for<'x, 'y> FnOnce(&mut ::kaya::Tpl<'x, 'y>) -> #arm_out_params),*
        {
            type Out = #cases_out<#(#arm_out_params),*>;
            fn declare(self, t: &mut ::kaya::Tpl<'_, '_>) -> Self::Out {
                #(
                    t.case_arm(#arm_indexes);
                    let #arm_names = (self.#arm_names)(t);
                )*
                #cases_out { #(#arm_names),* }
            }
        }

        #[allow(dead_code)]
        impl #name {
            #(#tokens)*
        }

        #(#patches)*
    }
    .into()
}

fn snake_case(name: &str) -> String {
    let mut out = String::new();
    for (i, ch) in name.chars().enumerate() {
        if ch.is_uppercase() {
            if i > 0 {
                out.push('_');
            }
            out.extend(ch.to_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}
