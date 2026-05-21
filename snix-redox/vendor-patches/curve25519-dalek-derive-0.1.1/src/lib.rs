//! Minimal guest-only shim for curve25519-dalek-derive.
//!
//! The real crate's proc macro stalls self-hosted Redox rustc in the snix VM.
//! This shim implements only the subset used by curve25519-dalek 4.x:
//! - `unsafe_target_feature` is a pass-through attribute.
//! - `unsafe_target_feature_specialize` duplicates an inline `mod spec { ... }`
//!   into `spec_<feature>` modules and strips `#[for_target_feature(...)]` helper
//!   attributes/items so downstream paths like `spec_avx2::...` resolve.

extern crate proc_macro;

use proc_macro::{Delimiter, Group, TokenStream, TokenTree};

#[proc_macro_attribute]
pub fn unsafe_target_feature(_attr: TokenStream, item: TokenStream) -> TokenStream {
    item
}

#[proc_macro_attribute]
pub fn unsafe_target_feature_specialize(attr: TokenStream, item: TokenStream) -> TokenStream {
    let specs = parse_specs(attr);
    if specs.is_empty() {
        return item;
    }

    let item_tokens: Vec<TokenTree> = item.clone().into_iter().collect();
    let Some((vis, name, body)) = split_inline_mod(&item_tokens) else {
        return item;
    };

    let mut out = String::new();
    for spec in specs {
        let module_name = format!("{}_{}", name, spec.suffix);
        let body = filter_for_target_feature(body.stream(), &spec.features).to_string();
        if !vis.is_empty() {
            out.push_str(&vis);
            out.push(' ');
        }
        out.push_str("mod ");
        out.push_str(&module_name);
        out.push_str(" { ");
        out.push_str(&body);
        out.push_str(" } ");
    }

    out.parse().unwrap_or(item)
}

#[derive(Debug)]
struct Spec {
    suffix: String,
    features: Vec<String>,
}

fn parse_specs(attr: TokenStream) -> Vec<Spec> {
    let mut specs = Vec::new();
    for tt in attr {
        if let TokenTree::Literal(lit) = tt {
            let text = strip_lit_quotes(&lit.to_string());
            if text.is_empty() {
                continue;
            }
            let features: Vec<String> = text
                .split(',')
                .map(|s| s.trim().replace('-', "_").replace(' ', ""))
                .filter(|s| !s.is_empty())
                .collect();
            if !features.is_empty() {
                specs.push(Spec {
                    suffix: features.join("_"),
                    features,
                });
            }
        } else if let TokenTree::Group(group) = tt {
            specs.extend(parse_specs(group.stream()));
        }
    }
    specs
}

fn split_inline_mod(tokens: &[TokenTree]) -> Option<(String, String, Group)> {
    let mut vis = Vec::new();
    let mut i = 0;
    while i < tokens.len() {
        match &tokens[i] {
            TokenTree::Ident(id) if id.to_string() == "mod" => {
                let name = match tokens.get(i + 1)? {
                    TokenTree::Ident(id) => id.to_string(),
                    _ => return None,
                };
                let body = match tokens.get(i + 2)? {
                    TokenTree::Group(g) if g.delimiter() == Delimiter::Brace => g.clone(),
                    _ => return None,
                };
                return Some((TokenStream::from_iter(vis).to_string(), name, body));
            }
            tt => vis.push(tt.clone()),
        }
        i += 1;
    }
    None
}

fn filter_for_target_feature(stream: TokenStream, enabled: &[String]) -> TokenStream {
    let tokens: Vec<TokenTree> = stream.into_iter().collect();
    let mut out: Vec<TokenTree> = Vec::new();
    let mut buffered_attrs: Vec<TokenTree> = Vec::new();
    let mut i = 0;

    while i < tokens.len() {
        if let Some(group) = attr_group(&tokens, i) {
            if attr_is_for_target_feature(group) {
                let wanted = attr_feature(group);
                if wanted.as_deref().is_some_and(|f| enabled.iter().any(|e| e == f)) {
                    // Helper attribute is consumed; keep preceding cfg/doc attrs.
                    i += 2;
                } else {
                    // Drop preceding attrs and the annotated item (target-specific import).
                    buffered_attrs.clear();
                    i = skip_item(&tokens, i + 2);
                }
            } else {
                buffered_attrs.push(tokens[i].clone());
                buffered_attrs.push(tokens[i + 1].clone());
                i += 2;
            }
            continue;
        }

        out.append(&mut buffered_attrs);
        out.push(tokens[i].clone());
        i += 1;
    }

    out.append(&mut buffered_attrs);
    TokenStream::from_iter(out)
}

fn attr_group(tokens: &[TokenTree], i: usize) -> Option<&Group> {
    match (tokens.get(i), tokens.get(i + 1)) {
        (Some(TokenTree::Punct(p)), Some(TokenTree::Group(g)))
            if p.as_char() == '#' && g.delimiter() == Delimiter::Bracket =>
        {
            Some(g)
        }
        _ => None,
    }
}

fn attr_is_for_target_feature(group: &Group) -> bool {
    group.stream().into_iter().next().is_some_and(|tt| match tt {
        TokenTree::Ident(id) => id.to_string() == "for_target_feature",
        _ => false,
    })
}

fn attr_feature(group: &Group) -> Option<String> {
    for tt in group.stream() {
        match tt {
            TokenTree::Literal(lit) => return Some(strip_lit_quotes(&lit.to_string()).replace('-', "_")),
            TokenTree::Group(g) => {
                if let Some(s) = attr_feature(&g) {
                    return Some(s);
                }
            }
            _ => {}
        }
    }
    None
}

fn skip_item(tokens: &[TokenTree], mut i: usize) -> usize {
    while i < tokens.len() {
        match &tokens[i] {
            TokenTree::Punct(p) if p.as_char() == ';' => return i + 1,
            TokenTree::Group(_) => return i + 1,
            _ => i += 1,
        }
    }
    i
}

fn strip_lit_quotes(s: &str) -> String {
    s.trim().trim_matches('"').to_string()
}
