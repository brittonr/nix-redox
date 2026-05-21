use proc_macro::{Delimiter, Group, TokenStream, TokenTree};

#[proc_macro_derive(Parser, attributes(arg, command, clap, group, value))]
pub fn derive_parser(input: TokenStream) -> TokenStream {
    let Some(name) = type_name(&input) else { return TokenStream::new(); };
    format!(
        r#"
impl clap::CommandFactory for {name} {{
    fn command() -> clap::Command {{ clap::Command::new(stringify!({name})) }}
    fn command_for_update() -> clap::Command {{ <Self as clap::CommandFactory>::command() }}
}}
impl clap::FromArgMatches for {name} {{
    fn from_arg_matches(_matches: &clap::ArgMatches) -> Result<Self, clap::Error> {{
        panic!("clap_derive Redox self-hosting shim: parsing {{}} is unavailable", stringify!({name}))
    }}
    fn update_from_arg_matches(&mut self, _matches: &clap::ArgMatches) -> Result<(), clap::Error> {{ Ok(()) }}
}}
impl clap::Parser for {name} {{}}
"#
    ).parse().unwrap_or_else(|_| TokenStream::new())
}

#[proc_macro_derive(Args, attributes(arg, command, clap, group, value))]
pub fn derive_args(input: TokenStream) -> TokenStream {
    let Some(name) = type_name(&input) else { return TokenStream::new(); };
    format!(
        r#"
impl clap::FromArgMatches for {name} {{
    fn from_arg_matches(_matches: &clap::ArgMatches) -> Result<Self, clap::Error> {{
        panic!("clap_derive Redox self-hosting shim: parsing {{}} is unavailable", stringify!({name}))
    }}
    fn update_from_arg_matches(&mut self, _matches: &clap::ArgMatches) -> Result<(), clap::Error> {{ Ok(()) }}
}}
impl clap::Args for {name} {{
    fn augment_args(cmd: clap::Command) -> clap::Command {{ cmd }}
    fn augment_args_for_update(cmd: clap::Command) -> clap::Command {{ cmd }}
}}
"#
    ).parse().unwrap_or_else(|_| TokenStream::new())
}

#[proc_macro_derive(Subcommand, attributes(arg, command, clap, group, value))]
pub fn derive_subcommand(input: TokenStream) -> TokenStream {
    let Some(name) = type_name(&input) else { return TokenStream::new(); };
    format!(
        r#"
impl clap::FromArgMatches for {name} {{
    fn from_arg_matches(_matches: &clap::ArgMatches) -> Result<Self, clap::Error> {{
        panic!("clap_derive Redox self-hosting shim: parsing {{}} is unavailable", stringify!({name}))
    }}
    fn update_from_arg_matches(&mut self, _matches: &clap::ArgMatches) -> Result<(), clap::Error> {{ Ok(()) }}
}}
impl clap::Subcommand for {name} {{
    fn augment_subcommands(cmd: clap::Command) -> clap::Command {{ cmd }}
    fn augment_subcommands_for_update(cmd: clap::Command) -> clap::Command {{ cmd }}
    fn has_subcommand(_name: &str) -> bool {{ false }}
}}
"#
    ).parse().unwrap_or_else(|_| TokenStream::new())
}

#[proc_macro_derive(ValueEnum, attributes(arg, command, clap, group, value))]
pub fn derive_value_enum(input: TokenStream) -> TokenStream {
    let Some(name) = type_name(&input) else { return TokenStream::new(); };
    format!(
        r#"
impl clap::ValueEnum for {name} {{
    fn value_variants<'a>() -> &'a [Self] {{ &[] }}
    fn to_possible_value(&self) -> Option<clap::builder::PossibleValue> {{ None }}
}}
"#
    ).parse().unwrap_or_else(|_| TokenStream::new())
}

fn type_name(input: &TokenStream) -> Option<String> {
    let mut saw_kind = false;
    for token in input.clone() {
        match token {
            TokenTree::Ident(ident) => {
                let s = ident.to_string();
                if saw_kind {
                    return Some(s);
                }
                if s == "struct" || s == "enum" || s == "union" {
                    saw_kind = true;
                }
            }
            TokenTree::Group(group) => {
                if group.delimiter() != Delimiter::None {
                    if let Some(name) = type_name_group(&group) {
                        return Some(name);
                    }
                }
            }
            _ => {}
        }
    }
    None
}

fn type_name_group(group: &Group) -> Option<String> {
    type_name(&group.stream())
}
