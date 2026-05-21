//! Minimal Redox self-hosting replacement for futures-macro.
//!
//! Redox rustc currently spins compiling the full upstream futures-rs proc-macro
//! implementation. snix only needs the simple two-argument join/try_join forms in
//! its binary closure, so implement those directly and fail loudly for other
//! futures-rs proc-macros if they are accidentally introduced.

extern crate proc_macro;

use proc_macro::{Delimiter, TokenStream, TokenTree};

fn unsupported_macro(name: &str) -> TokenStream {
    format!(
        "compile_error!(\"futures-macro replacement does not implement {} on Redox self-hosting\");",
        name
    )
    .parse()
    .expect("static compile_error parses")
}

fn split_two_args(input: TokenStream, name: &str) -> Result<(TokenStream, TokenStream), TokenStream> {
    let mut depth = 0usize;
    let mut first = Vec::new();
    let mut second = Vec::new();
    let mut seen_comma = false;

    for token in input {
        match &token {
            TokenTree::Group(group) => {
                if group.delimiter() != Delimiter::None {
                    if seen_comma {
                        second.push(token);
                    } else {
                        first.push(token);
                    }
                    continue;
                }
            }
            TokenTree::Punct(punct) if punct.as_char() == '<' => depth += 1,
            TokenTree::Punct(punct) if punct.as_char() == '>' && depth > 0 => depth -= 1,
            TokenTree::Punct(punct) if punct.as_char() == ',' && depth == 0 => {
                if seen_comma {
                    return Err(unsupported_macro(name));
                }
                seen_comma = true;
                continue;
            }
            _ => {}
        }

        if seen_comma {
            second.push(token);
        } else {
            first.push(token);
        }
    }

    if !seen_comma || first.is_empty() || second.is_empty() {
        return Err(unsupported_macro(name));
    }

    Ok((first.into_iter().collect(), second.into_iter().collect()))
}

#[proc_macro]
pub fn join_internal(input: TokenStream) -> TokenStream {
    match split_two_args(input, "join!") {
        Ok((a, b)) => format!("__futures_crate::future::join({}, {}).await", a, b)
            .parse()
            .expect("generated join parses"),
        Err(err) => err,
    }
}

#[proc_macro]
pub fn try_join_internal(input: TokenStream) -> TokenStream {
    match split_two_args(input, "try_join!") {
        Ok((a, b)) => format!("__futures_crate::future::try_join({}, {}).await", a, b)
            .parse()
            .expect("generated try_join parses"),
        Err(err) => err,
    }
}

#[proc_macro]
pub fn select_internal(_input: TokenStream) -> TokenStream {
    unsupported_macro("select!")
}

#[proc_macro]
pub fn select_biased_internal(_input: TokenStream) -> TokenStream {
    unsupported_macro("select_biased!")
}

#[proc_macro_attribute]
pub fn test_internal(_input: TokenStream, item: TokenStream) -> TokenStream {
    item
}

#[proc_macro]
pub fn stream_select_internal(_input: TokenStream) -> TokenStream {
    unsupported_macro("stream_select!")
}
