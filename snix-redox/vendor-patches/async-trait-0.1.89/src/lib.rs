use proc_macro::TokenStream;
use proc_macro2::{Span, TokenStream as TokenStream2};
use quote::{quote, ToTokens};
use syn::parse_quote;
use syn::punctuated::Punctuated;
use syn::token::Comma;
use syn::visit_mut::{self, VisitMut};
use syn::{
    parse_macro_input, FnArg, GenericParam, ImplItem, ImplItemFn, Item, ItemImpl, ItemTrait,
    Lifetime, LifetimeParam, Pat, PatIdent, ReturnType, Signature, TraitItem, TraitItemFn, Type,
    TypeReference, WhereClause, WherePredicate,
};

#[proc_macro_attribute]
pub fn async_trait(_args: TokenStream, input: TokenStream) -> TokenStream {
    let item = parse_macro_input!(input as Item);
    match item {
        Item::Trait(item) => expand_trait(item).into(),
        Item::Impl(item) => expand_impl(item).into(),
        other => other.into_token_stream().into(),
    }
}

fn expand_trait(mut item: ItemTrait) -> TokenStream2 {
    for trait_item in &mut item.items {
        if let TraitItem::Fn(method) = trait_item {
            if method.sig.asyncness.is_some() {
                transform_trait_method(method);
            }
        }
    }
    quote!(#item)
}

fn expand_impl(mut item: ItemImpl) -> TokenStream2 {
    for impl_item in &mut item.items {
        if let ImplItem::Fn(method) = impl_item {
            if method.sig.asyncness.is_some() {
                transform_impl_method(method);
            }
        }
    }
    quote!(#item)
}

fn transform_trait_method(method: &mut TraitItemFn) {
    let output = output_type(&method.sig.output);
    let async_lt = ensure_async_lifetime(&mut method.sig);
    let arg_lts = name_elided_arg_lifetimes(&mut method.sig);
    method.sig.asyncness = None;
    method.sig.output = parse_quote!(-> ::core::pin::Pin<Box<dyn ::core::future::Future<Output = #output> + Send + #async_lt>>);
    ensure_lifetime_params(&mut method.sig, &arg_lts);
    add_async_where_bounds(&mut method.sig, &async_lt, &arg_lts, true);

    if let Some(default) = method.default.take() {
        method.default = Some(parse_quote!({ Box::pin(async move #default) }));
    }
}

fn transform_impl_method(method: &mut ImplItemFn) {
    let output = output_type(&method.sig.output);
    let async_lt = ensure_async_lifetime(&mut method.sig);
    let arg_lts = name_elided_arg_lifetimes(&mut method.sig);
    method.sig.asyncness = None;
    method.sig.output = parse_quote!(-> ::core::pin::Pin<Box<dyn ::core::future::Future<Output = #output> + Send + #async_lt>>);
    ensure_lifetime_params(&mut method.sig, &arg_lts);
    add_async_where_bounds(&mut method.sig, &async_lt, &arg_lts, false);
    let body = method.block.clone();
    method.block = parse_quote!({
        Box::pin(async move {
            let __async_trait_result: #output = (async move #body).await;
            __async_trait_result
        })
    });
}

fn output_type(output: &ReturnType) -> Type {
    match output {
        ReturnType::Default => parse_quote!(()),
        ReturnType::Type(_, ty) => (**ty).clone(),
    }
}

fn ensure_async_lifetime(sig: &mut Signature) -> Lifetime {
    let lt = Lifetime::new("'async_trait", Span::call_site());
    let exists = sig.generics.params.iter().any(|param| match param {
        GenericParam::Lifetime(lp) => lp.lifetime.ident == "async_trait",
        _ => false,
    });
    if !exists {
        sig.generics.params.insert(0, GenericParam::Lifetime(LifetimeParam::new(lt.clone())));
    }
    lt
}

fn name_elided_arg_lifetimes(sig: &mut Signature) -> Vec<Lifetime> {
    let mut out = Vec::new();
    let mut next = 0usize;
    for arg in &mut sig.inputs {
        match arg {
            FnArg::Receiver(receiver) => {
                if let Some((_and, lifetime)) = &mut receiver.reference {
                    if lifetime.is_none() {
                        let lt = fresh_lifetime(&mut next);
                        *lifetime = Some(lt.clone());
                        out.push(lt);
                    } else if let Some(lt) = lifetime {
                        out.push(lt.clone());
                    }
                }
            }
            FnArg::Typed(pat_ty) => {
                let prefix = pat_ident_prefix(&pat_ty.pat).unwrap_or_else(|| "life".to_string());
                let mut namer = RefLifetimeNamer { out: Vec::new(), next: 0, prefix };
                namer.visit_type_mut(&mut pat_ty.ty);
                out.extend(namer.out);
            }
        }
    }
    dedup_lifetimes(out)
}

struct RefLifetimeNamer {
    out: Vec<Lifetime>,
    next: usize,
    prefix: String,
}

impl VisitMut for RefLifetimeNamer {
    fn visit_type_reference_mut(&mut self, node: &mut TypeReference) {
        if let Some(lt) = &node.lifetime {
            if lt.ident != "_" {
                self.out.push(lt.clone());
            } else {
                let new_lt = Lifetime::new(&format!("'{}_{}", self.prefix, self.next), Span::call_site());
                self.next += 1;
                node.lifetime = Some(new_lt.clone());
                self.out.push(new_lt);
            }
        } else {
            let new_lt = Lifetime::new(&format!("'{}_{}", self.prefix, self.next), Span::call_site());
            self.next += 1;
            node.lifetime = Some(new_lt.clone());
            self.out.push(new_lt);
        }
        visit_mut::visit_type_reference_mut(self, node);
    }
}

fn pat_ident_prefix(pat: &Pat) -> Option<String> {
    if let Pat::Ident(PatIdent { ident, .. }) = pat {
        Some(ident.to_string())
    } else {
        None
    }
}

fn fresh_lifetime(next: &mut usize) -> Lifetime {
    let lt = Lifetime::new(&format!("'life{}", *next), Span::call_site());
    *next += 1;
    lt
}

fn dedup_lifetimes(lts: Vec<Lifetime>) -> Vec<Lifetime> {
    let mut seen = Vec::<String>::new();
    let mut out = Vec::new();
    for lt in lts {
        let name = lt.ident.to_string();
        if name == "static" || name == "async_trait" {
            continue;
        }
        if !seen.iter().any(|s| s == &name) {
            seen.push(name);
            out.push(lt);
        }
    }
    out
}

fn ensure_lifetime_params(sig: &mut Signature, lts: &[Lifetime]) {
    for lt in lts.iter().rev() {
        let exists = sig.generics.params.iter().any(|param| match param {
            GenericParam::Lifetime(lp) => lp.lifetime.ident == lt.ident,
            _ => false,
        });
        if !exists {
            sig.generics
                .params
                .insert(0, GenericParam::Lifetime(LifetimeParam::new(lt.clone())));
        }
    }
}

fn add_async_where_bounds(
    sig: &mut Signature,
    async_lt: &Lifetime,
    arg_lts: &[Lifetime],
    add_self: bool,
) {
    let where_clause = sig
        .generics
        .where_clause
        .get_or_insert_with(|| WhereClause {
            where_token: Default::default(),
            predicates: Punctuated::<WherePredicate, Comma>::new(),
        });
    for lt in arg_lts {
        let pred: WherePredicate = parse_quote!(#lt: #async_lt);
        where_clause.predicates.push(pred);
    }
    if add_self {
        let pred: WherePredicate = parse_quote!(Self: #async_lt);
        where_clause.predicates.push(pred);
    }
}
