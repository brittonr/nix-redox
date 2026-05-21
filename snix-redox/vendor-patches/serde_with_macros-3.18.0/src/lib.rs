use proc_macro::TokenStream;

#[proc_macro_attribute]
pub fn skip_serializing_none(_args: TokenStream, input: TokenStream) -> TokenStream {
    input
}

#[proc_macro_attribute]
pub fn serde_as(_args: TokenStream, input: TokenStream) -> TokenStream {
    input
}

#[proc_macro_derive(DeserializeFromStr, attributes(serde_with))]
pub fn deserialize_from_str(input: TokenStream) -> TokenStream {
    derive_from_str_like(input, true)
}

#[proc_macro_derive(SerializeDisplay, attributes(serde_with))]
pub fn serialize_display(input: TokenStream) -> TokenStream {
    derive_display_like(input, false)
}

#[proc_macro_derive(SerializeDisplayAlt, attributes(serde_with))]
pub fn serialize_display_alt(input: TokenStream) -> TokenStream {
    derive_display_like(input, true)
}

#[proc_macro_derive(__private_consume_serde_as_attributes, attributes(serde_as, serialize_always))]
pub fn private_consume_serde_as_attributes(_input: TokenStream) -> TokenStream {
    TokenStream::new()
}

#[proc_macro_attribute]
pub fn serde_conv(_args: TokenStream, input: TokenStream) -> TokenStream {
    input
}

fn derive_from_str_like(input: TokenStream, _deserialize: bool) -> TokenStream {
    let src = input.to_string();
    let Some(name) = find_type_name(&src) else { return TokenStream::new(); };
    let out = format!(
        r#"
        impl<'de> ::serde::Deserialize<'de> for {name} {{
            fn deserialize<D>(deserializer: D) -> ::core::result::Result<Self, D::Error>
            where
                D: ::serde::Deserializer<'de>,
            {{
                let s = <::std::string::String as ::serde::Deserialize>::deserialize(deserializer)?;
                <Self as ::core::str::FromStr>::from_str(&s).map_err(::serde::de::Error::custom)
            }}
        }}
        "#,
        name = name
    );
    out.parse().unwrap_or_else(|_| TokenStream::new())
}

fn derive_display_like(input: TokenStream, alternate: bool) -> TokenStream {
    let src = input.to_string();
    let Some(name) = find_type_name(&src) else { return TokenStream::new(); };
    let fmt = if alternate { "format!(\"{:#}\", self)" } else { "format!(\"{}\", self)" };
    let out = format!(
        r#"
        impl ::serde::Serialize for {name} {{
            fn serialize<S>(&self, serializer: S) -> ::core::result::Result<S::Ok, S::Error>
            where
                S: ::serde::Serializer,
            {{
                serializer.serialize_str(&{fmt})
            }}
        }}
        "#,
        name = name,
        fmt = fmt
    );
    out.parse().unwrap_or_else(|_| TokenStream::new())
}

fn find_type_name(src: &str) -> Option<String> {
    let mut prev = "";
    for tok in src.split(|c: char| !(c == '_' || c.is_ascii_alphanumeric())) {
        if prev == "struct" || prev == "enum" || prev == "union" {
            if !tok.is_empty() {
                return Some(tok.to_string());
            }
        }
        if !tok.is_empty() {
            prev = tok;
        }
    }
    None
}
