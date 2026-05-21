use proc_macro::{Delimiter, Group, TokenStream, TokenTree};

#[proc_macro_attribute]
pub fn pin_project(_args: TokenStream, input: TokenStream) -> TokenStream {
    strip_pin_attrs(input)
}

#[proc_macro_attribute]
pub fn pinned_drop(_args: TokenStream, input: TokenStream) -> TokenStream {
    input
}

#[proc_macro_derive(__PinProjectInternalDerive, attributes(pin))]
pub fn __pin_project_internal_derive(_input: TokenStream) -> TokenStream {
    TokenStream::new()
}

fn strip_pin_attrs(input: TokenStream) -> TokenStream {
    let mut out = Vec::new();
    let mut iter = input.into_iter().peekable();
    while let Some(tt) = iter.next() {
        if is_pin_attr(&tt, iter.peek()) {
            iter.next();
            continue;
        }
        match tt {
            TokenTree::Group(g) => {
                let mut ng = Group::new(g.delimiter(), strip_pin_attrs(g.stream()));
                ng.set_span(g.span());
                out.push(TokenTree::Group(ng));
            }
            other => out.push(other),
        }
    }
    out.into_iter().collect()
}

fn is_pin_attr(tt: &TokenTree, next: Option<&TokenTree>) -> bool {
    match (tt, next) {
        (TokenTree::Punct(p), Some(TokenTree::Group(g)))
            if p.as_char() == '#' && g.delimiter() == Delimiter::Bracket =>
        {
            g.stream().to_string().trim() == "pin"
        }
        _ => false,
    }
}
