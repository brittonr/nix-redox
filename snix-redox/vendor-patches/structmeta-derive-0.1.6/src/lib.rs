use proc_macro::TokenStream;
use quote::{format_ident, quote};
use syn::{parse_macro_input, Data, DeriveInput, Fields, GenericArgument, PathArguments, Type};

#[proc_macro_derive(ToTokens, attributes(to_tokens))]
pub fn derive_to_tokens(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    expand_to_tokens(&input).unwrap_or_else(|e| e.to_compile_error()).into()
}

#[proc_macro_derive(Parse, attributes(parse, to_tokens))]
pub fn derive_parse(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    expand_parse(&input).unwrap_or_else(|e| e.to_compile_error()).into()
}

#[proc_macro_derive(StructMeta, attributes(struct_meta))]
pub fn derive_struct_meta(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    expand_struct_meta(&input).unwrap_or_else(|e| e.to_compile_error()).into()
}

fn expand_to_tokens(input: &DeriveInput) -> syn::Result<proc_macro2::TokenStream> {
    let name = &input.ident;
    let (impl_generics, ty_generics, where_clause) = input.generics.split_for_impl();
    let body = match &input.data {
        Data::Struct(data) => to_tokens_fields(quote!(self), &data.fields),
        Data::Enum(data) => {
            let arms = data.variants.iter().map(|v| {
                let vname = &v.ident;
                match &v.fields {
                    Fields::Named(fields) => {
                        let bindings: Vec<_> = fields.named.iter().map(|f| f.ident.as_ref().unwrap()).collect();
                        let toks = bindings.iter().map(|b| quote!(::quote::ToTokens::to_tokens(#b, tokens);));
                        quote!(Self::#vname { #( #bindings ),* } => { #( #toks )* })
                    }
                    Fields::Unnamed(fields) => {
                        let bindings: Vec<_> = (0..fields.unnamed.len()).map(|i| format_ident!("f{}", i)).collect();
                        let toks = bindings.iter().map(|b| quote!(::quote::ToTokens::to_tokens(#b, tokens);));
                        quote!(Self::#vname( #( #bindings ),* ) => { #( #toks )* })
                    }
                    Fields::Unit => quote!(Self::#vname => {}),
                }
            });
            quote!(match self { #( #arms ),* })
        }
        _ => return Err(syn::Error::new_spanned(input, "unsupported input for ToTokens")),
    };
    Ok(quote! {
        impl #impl_generics ::quote::ToTokens for #name #ty_generics #where_clause {
            fn to_tokens(&self, tokens: &mut ::proc_macro2::TokenStream) {
                #body
            }
        }
    })
}

fn to_tokens_fields(base: proc_macro2::TokenStream, fields: &Fields) -> proc_macro2::TokenStream {
    match fields {
        Fields::Named(fields) => {
            let toks = fields.named.iter().map(|f| {
                let ident = f.ident.as_ref().unwrap();
                quote!(::quote::ToTokens::to_tokens(&#base.#ident, tokens);)
            });
            quote!(#( #toks )*)
        }
        Fields::Unnamed(fields) => {
            let toks = (0..fields.unnamed.len()).map(|i| {
                let idx = syn::Index::from(i);
                quote!(::quote::ToTokens::to_tokens(&#base.#idx, tokens);)
            });
            quote!(#( #toks )*)
        }
        Fields::Unit => quote!(),
    }
}

fn expand_parse(input: &DeriveInput) -> syn::Result<proc_macro2::TokenStream> {
    let name = &input.ident;
    let (impl_generics, ty_generics, where_clause) = input.generics.split_for_impl();
    let body = match &input.data {
        Data::Struct(data) => parse_struct_constructor(name, &data.fields)?,
        Data::Enum(data) => {
            let mut branches = Vec::new();
            for v in &data.variants {
                let vname = &v.ident;
                match &v.fields {
                    Fields::Named(fields) => {
                        let first = fields.named.iter().next().and_then(|f| f.ident.as_ref()).ok_or_else(|| syn::Error::new_spanned(v, "empty named variants are unsupported"))?;
                        let mut parse_fields = Vec::new();
                        let mut names = Vec::new();
                        for f in &fields.named {
                            let fname = f.ident.as_ref().unwrap();
                            names.push(fname.clone());
                            parse_fields.push(parse_one_value(fname, &f.ty, false));
                        }
                        branches.push(quote! {
                            {
                                let fork = input.fork();
                                if fork.parse::<::syn::Ident>().is_ok() && fork.parse::<::syn::Token![=]>().is_ok() {
                                    #( #parse_fields )*
                                    return Ok(Self::#vname { #( #names ),* });
                                }
                            }
                        });
                        let _ = first;
                    }
                    Fields::Unnamed(fields) => {
                        let vars: Vec<_> = (0..fields.unnamed.len()).map(|i| format_ident!("v{}", i)).collect();
                        let parses = fields.unnamed.iter().zip(vars.iter()).map(|(f, var)| parse_one_value(var, &f.ty, has_attr(&f.attrs, "parse", "terminated")));
                        branches.push(quote! {
                            {
                                let fork = input.fork();
                                #( #parses )*
                                input.advance_to(&fork);
                                return Ok(Self::#vname( #( #vars ),* ));
                            }
                        });
                    }
                    Fields::Unit => branches.push(quote!(return Ok(Self::#vname);)),
                }
            }
            quote! {
                use ::syn::parse::discouraged::Speculative;
                #( #branches )*
                Err(input.error("failed to parse enum variant"))
            }
        }
        _ => return Err(syn::Error::new_spanned(input, "unsupported input for Parse")),
    };
    Ok(quote! {
        impl #impl_generics ::syn::parse::Parse for #name #ty_generics #where_clause {
            fn parse(input: ::syn::parse::ParseStream) -> ::syn::Result<Self> {
                #body
            }
        }
    })
}

fn parse_struct_constructor(name: &syn::Ident, fields: &Fields) -> syn::Result<proc_macro2::TokenStream> {
    match fields {
        Fields::Unnamed(fields) => {
            let vars: Vec<_> = (0..fields.unnamed.len()).map(|i| format_ident!("v{}", i)).collect();
            let parses = fields.unnamed.iter().zip(vars.iter()).map(|(f, var)| parse_one_value(var, &f.ty, has_attr(&f.attrs, "parse", "terminated")));
            Ok(quote! { #( #parses )* Ok(#name( #( #vars ),* )) })
        }
        Fields::Named(fields) => {
            let names: Vec<_> = fields.named.iter().map(|f| f.ident.as_ref().unwrap().clone()).collect();
            let inits = names.iter().map(|n| quote!(let mut #n = ::std::default::Default::default();));
            let arms = fields.named.iter().map(|f| {
                let fname = f.ident.as_ref().unwrap();
                let key = fname.to_string();
                let ty = &f.ty;
                if is_flag(ty) {
                    quote!(#key => { #fname = ::structmeta::Flag { span: Some(name_span) }; })
                } else if let Some(inner) = option_inner(ty) {
                    if let Some(vec_inner) = vec_inner(inner) {
                        quote!(#key => { let content; ::syn::parenthesized!(content in input); let parsed = content.parse_terminated::<#vec_inner, ::syn::Token![,]>(#vec_inner::parse)?; #fname = Some(parsed.into_iter().collect()); })
                    } else {
                        quote!(#key => { input.parse::<::syn::Token![=]>()?; #fname = Some(input.parse()?); })
                    }
                } else {
                    quote!(#key => { input.parse::<::syn::Token![=]>()?; #fname = input.parse()?; })
                }
            });
            let unnamed_field = fields.named.iter().find(|f| has_attr(&f.attrs, "struct_meta", "unnamed"));
            let unnamed_assign = if let Some(f) = unnamed_field {
                let fname = f.ident.as_ref().unwrap();
                quote!(#fname = Some(input.parse()?);)
            } else {
                quote!(return Err(input.error("unexpected unnamed argument"));)
            };
            let hashmap_arms = fields.named.iter().filter_map(|f| {
                let fname = f.ident.as_ref().unwrap();
                let ty = f.ty.clone();
                if type_string(&ty).contains("HashMap") && type_string(&ty).contains("NameValue") {
                    let val_ty = name_value_inner(&ty).unwrap_or_else(|| syn::parse_quote!(::syn::Expr));
                    Some(quote! {
                        input.parse::<::syn::Token![=]>()?;
                        let value: #val_ty = input.parse()?;
                        #fname.insert(name_string, ::structmeta::NameValue { name_span, value });
                        parsed_rest = true;
                    })
                } else { None }
            });
            Ok(quote! {
                #( #inits )*
                while !input.is_empty() {
                    let mut parsed_rest = false;
                    if input.peek(::syn::Ident) {
                        let name_ident: ::syn::Ident = input.parse()?;
                        let name_span = name_ident.span();
                        let name_string = name_ident.to_string();
                        match name_string.as_str() {
                            #( #arms ),*,
                            _ => { #( #hashmap_arms )* if !parsed_rest { return Err(input.error("unknown structmeta argument")); } }
                        }
                    } else {
                        #unnamed_assign
                    }
                    if input.peek(::syn::Token![,]) { let _comma: ::syn::Token![,] = input.parse()?; }
                }
                Ok(Self { #( #names ),* })
            })
        }
        Fields::Unit => Ok(quote!(Ok(#name))),
    }
}

fn expand_struct_meta(input: &DeriveInput) -> syn::Result<proc_macro2::TokenStream> {
    // structmeta::StructMeta ultimately provides syn::parse::Parse behavior for the
    // crates in the self-hosting graph.  A direct Parse impl is enough for their
    // Attribute::parse_args / parse2 use sites and avoids compiling upstream's much
    // heavier proc-macro on Redox.
    expand_parse(input)
}

fn parse_one_value(var: &syn::Ident, ty: &Type, terminated: bool) -> proc_macro2::TokenStream {
    if terminated {
        if let Some((inner, punct)) = punctuated_args(ty) {
            quote!(let #var: #ty = input.parse_terminated::<#inner, #punct>(#inner::parse)?;)
        } else {
            quote!(let #var: #ty = input.parse()?;)
        }
    } else {
        quote!(let #var: #ty = input.parse()?;)
    }
}

fn has_attr(attrs: &[syn::Attribute], attr_name: &str, word: &str) -> bool {
    attrs.iter().any(|a| a.path.is_ident(attr_name) && a.tokens.to_string().contains(word))
}

fn type_string(ty: &Type) -> String { quote!(#ty).to_string().replace(' ', "") }
fn is_flag(ty: &Type) -> bool { type_string(ty).ends_with("Flag") || type_string(ty).contains("::Flag") }

fn option_inner(ty: &Type) -> Option<&Type> {
    path_inner(ty, "Option", 0)
}
fn vec_inner(ty: &Type) -> Option<&Type> {
    path_inner(ty, "Vec", 0)
}
fn path_inner<'a>(ty: &'a Type, last: &str, idx: usize) -> Option<&'a Type> {
    if let Type::Path(tp) = ty {
        let seg = tp.path.segments.last()?;
        if seg.ident == last {
            if let PathArguments::AngleBracketed(ab) = &seg.arguments {
                if let Some(GenericArgument::Type(t)) = ab.args.iter().nth(idx) { return Some(t); }
            }
        }
    }
    None
}
fn punctuated_args(ty: &Type) -> Option<(&Type, &Type)> {
    if let Type::Path(tp) = ty {
        let seg = tp.path.segments.last()?;
        if seg.ident == "Punctuated" {
            if let PathArguments::AngleBracketed(ab) = &seg.arguments {
                let mut tys = ab.args.iter().filter_map(|a| if let GenericArgument::Type(t) = a { Some(t) } else { None });
                return Some((tys.next()?, tys.next()?));
            }
        }
    }
    None
}
fn name_value_inner(ty: &Type) -> Option<Type> {
    if let Type::Path(tp) = ty {
        let seg = tp.path.segments.last()?;
        if seg.ident == "HashMap" {
            if let PathArguments::AngleBracketed(ab) = &seg.arguments {
                for arg in &ab.args {
                    if let GenericArgument::Type(Type::Path(vp)) = arg {
                        let vseg = vp.path.segments.last()?;
                        if vseg.ident == "NameValue" {
                            if let PathArguments::AngleBracketed(vab) = &vseg.arguments {
                                if let Some(GenericArgument::Type(inner)) = vab.args.iter().next() { return Some(inner.clone()); }
                            }
                        }
                    }
                }
            }
        }
    }
    None
}
