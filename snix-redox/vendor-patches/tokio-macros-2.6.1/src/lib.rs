extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro_attribute]
pub fn main(_attr: TokenStream, item: TokenStream) -> TokenStream {
    item
}

#[proc_macro_attribute]
pub fn test(_attr: TokenStream, item: TokenStream) -> TokenStream {
    item
}

#[proc_macro_attribute]
pub fn main_rt(attr: TokenStream, item: TokenStream) -> TokenStream {
    main(attr, item)
}

#[proc_macro_attribute]
pub fn test_rt(attr: TokenStream, item: TokenStream) -> TokenStream {
    test(attr, item)
}

#[proc_macro_attribute]
pub fn main_fail(attr: TokenStream, item: TokenStream) -> TokenStream {
    main(attr, item)
}

#[proc_macro_attribute]
pub fn test_fail(attr: TokenStream, item: TokenStream) -> TokenStream {
    test(attr, item)
}

#[proc_macro]
pub fn select_priv_declare_output_enum(input: TokenStream) -> TokenStream {
    input
}

#[proc_macro]
pub fn select_priv_clean_pattern(input: TokenStream) -> TokenStream {
    input
}
