use proc_macro::TokenStream;

const CURRENT_MAJOR: u64 = 1;
const CURRENT_MINOR: u64 = 92;

fn parse_version(attr: TokenStream) -> Option<(u64, u64)> {
    let text = attr.to_string();
    let mut nums = text
        .split(|c: char| !c.is_ascii_digit())
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<u64>().ok());
    let major = nums.next()?;
    let minor = nums.next().unwrap_or(0);
    Some((major, minor))
}

fn current_is_at_least(version: (u64, u64)) -> bool {
    (CURRENT_MAJOR, CURRENT_MINOR) >= version
}

#[proc_macro_attribute]
pub fn stable(_attr: TokenStream, item: TokenStream) -> TokenStream { item }

#[proc_macro_attribute]
pub fn beta(_attr: TokenStream, _item: TokenStream) -> TokenStream { TokenStream::new() }

#[proc_macro_attribute]
pub fn nightly(_attr: TokenStream, _item: TokenStream) -> TokenStream { TokenStream::new() }

#[proc_macro_attribute]
pub fn since(attr: TokenStream, item: TokenStream) -> TokenStream {
    match parse_version(attr) {
        Some(version) if current_is_at_least(version) => item,
        Some(_) => TokenStream::new(),
        None => item,
    }
}

#[proc_macro_attribute]
pub fn before(attr: TokenStream, item: TokenStream) -> TokenStream {
    match parse_version(attr) {
        Some(version) if current_is_at_least(version) => TokenStream::new(),
        Some(_) => item,
        None => TokenStream::new(),
    }
}

#[proc_macro_attribute]
pub fn not(_attr: TokenStream, item: TokenStream) -> TokenStream { item }

#[proc_macro_attribute]
pub fn all(_attr: TokenStream, item: TokenStream) -> TokenStream { item }

#[proc_macro_attribute]
pub fn any(_attr: TokenStream, item: TokenStream) -> TokenStream { item }

#[proc_macro_attribute]
pub fn attr(_attr: TokenStream, item: TokenStream) -> TokenStream { item }

#[proc_macro]
pub fn cfg(_input: TokenStream) -> TokenStream { "true".parse().unwrap() }
