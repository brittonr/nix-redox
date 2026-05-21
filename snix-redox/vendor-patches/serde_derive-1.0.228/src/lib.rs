extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro_derive(Serialize, attributes(serde))]
pub fn derive_serialize(input: TokenStream) -> TokenStream {
    match derive_impl(input, DeriveKind::Serialize) {
        Ok(output) => output.parse().unwrap_or_else(|_| TokenStream::new()),
        Err(message) => compile_error(&message),
    }
}

#[proc_macro_derive(Deserialize, attributes(serde))]
pub fn derive_deserialize(input: TokenStream) -> TokenStream {
    match derive_impl(input, DeriveKind::Deserialize) {
        Ok(output) => output.parse().unwrap_or_else(|_| TokenStream::new()),
        Err(message) => compile_error(&message),
    }
}

enum DeriveKind {
    Serialize,
    Deserialize,
}

fn compile_error(message: &str) -> TokenStream {
    format!("compile_error!({:?});", message)
        .parse()
        .unwrap_or_else(|_| TokenStream::new())
}

fn derive_impl(input: TokenStream, kind: DeriveKind) -> Result<String, String> {
    let source = input.to_string();
    let parsed = parse_item(&source)?;
    let ty = if parsed.type_generics.is_empty() {
        parsed.name.clone()
    } else {
        format!("{}{}", parsed.name, parsed.type_generics)
    };

    let output = match kind {
        DeriveKind::Serialize => format!(
            "impl {} ::serde::Serialize for {} {} {{\n  fn serialize<__S>(&self, __serializer: __S) -> ::core::result::Result<__S::Ok, __S::Error>\n  where\n    __S: ::serde::Serializer,\n  {{\n    __serializer.serialize_unit()\n  }}\n}}",
            parsed.impl_generics, ty, parsed.where_clause
        ),
        DeriveKind::Deserialize => {
            let impl_generics = add_deserialize_lifetime(&parsed.impl_generics);
            format!(
                "impl {} ::serde::Deserialize<'__serde_de> for {} {} {{\n  fn deserialize<__D>(__deserializer: __D) -> ::core::result::Result<Self, __D::Error>\n  where\n    __D: ::serde::Deserializer<'__serde_de>,\n  {{\n    let _ = __deserializer;\n    ::core::result::Result::Err(<__D::Error as ::serde::de::Error>::custom(\"serde_derive shim cannot deserialize at runtime\"))\n  }}\n}}",
                impl_generics, ty, parsed.where_clause
            )
        }
    };
    Ok(output)
}

struct ParsedItem {
    name: String,
    impl_generics: String,
    type_generics: String,
    where_clause: String,
}

fn parse_item(source: &str) -> Result<ParsedItem, String> {
    let tokens = lex(source);
    let kind_idx = tokens
        .iter()
        .position(|token| token == "struct" || token == "enum" || token == "union")
        .ok_or_else(|| format!("serde_derive shim could not find item kind in `{}`", source))?;
    let name = tokens
        .get(kind_idx + 1)
        .ok_or_else(|| "serde_derive shim could not find item name".to_string())?
        .clone();

    let mut idx = kind_idx + 2;
    let mut generic_tokens = Vec::new();
    if tokens.get(idx).map(String::as_str) == Some("<") {
        let start = idx;
        let mut depth = 0isize;
        while idx < tokens.len() {
            let token = &tokens[idx];
            if token == "<" {
                depth += 1;
            } else if token == ">" {
                depth -= 1;
                if depth == 0 {
                    idx += 1;
                    generic_tokens = tokens[start + 1..idx - 1].to_vec();
                    break;
                }
            }
            idx += 1;
        }
        if depth != 0 {
            return Err("serde_derive shim found unbalanced generics".to_string());
        }
    }

    let mut where_tokens = Vec::new();
    if tokens.get(idx).map(String::as_str) == Some("where") {
        let start = idx;
        let mut depth = 0isize;
        while idx < tokens.len() {
            let token = &tokens[idx];
            match token.as_str() {
                "<" | "(" | "[" => depth += 1,
                ">" | ")" | "]" => depth -= 1,
                "{" | ";" if depth == 0 => break,
                _ => {}
            }
            idx += 1;
        }
        where_tokens = tokens[start..idx].to_vec();
    }

    let impl_generics = sanitize_impl_generics(&generic_tokens);
    let type_generics = make_type_generics(&generic_tokens);
    let where_clause = join_tokens(&where_tokens);

    Ok(ParsedItem {
        name,
        impl_generics,
        type_generics,
        where_clause,
    })
}

fn add_deserialize_lifetime(impl_generics: &str) -> String {
    if impl_generics.is_empty() {
        "<'__serde_de>".to_string()
    } else {
        let inner = impl_generics
            .strip_prefix('<')
            .and_then(|s| s.strip_suffix('>'))
            .unwrap_or(impl_generics);
        if inner.trim().is_empty() {
            "<'__serde_de>".to_string()
        } else {
            format!("<'__serde_de, {}>", inner)
        }
    }
}

fn sanitize_impl_generics(tokens: &[String]) -> String {
    if tokens.is_empty() {
        return String::new();
    }
    let mut params = split_top_level_commas(tokens)
        .into_iter()
        .map(|param| strip_default(&param))
        .filter(|param| !param.is_empty())
        .collect::<Vec<_>>();
    if params.is_empty() {
        String::new()
    } else {
        format!("<{}>", params.join(", "))
    }
}

fn make_type_generics(tokens: &[String]) -> String {
    if tokens.is_empty() {
        return String::new();
    }
    let args = split_top_level_commas(tokens)
        .into_iter()
        .filter_map(|param| generic_arg_name(&param))
        .collect::<Vec<_>>();
    if args.is_empty() {
        String::new()
    } else {
        format!("<{}>", args.join(", "))
    }
}

fn split_top_level_commas(tokens: &[String]) -> Vec<Vec<String>> {
    let mut out = Vec::new();
    let mut current = Vec::new();
    let mut depth = 0isize;
    for token in tokens {
        match token.as_str() {
            "<" | "(" | "[" => {
                depth += 1;
                current.push(token.clone());
            }
            ">" | ")" | "]" => {
                depth -= 1;
                current.push(token.clone());
            }
            "," if depth == 0 => {
                out.push(current);
                current = Vec::new();
            }
            _ => current.push(token.clone()),
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

fn strip_default(tokens: &[String]) -> String {
    let mut kept = Vec::new();
    let mut depth = 0isize;
    for token in tokens {
        match token.as_str() {
            "<" | "(" | "[" => depth += 1,
            ">" | ")" | "]" => depth -= 1,
            "=" if depth == 0 => break,
            _ => {}
        }
        kept.push(token.clone());
    }
    join_tokens(&kept)
}

fn generic_arg_name(tokens: &[String]) -> Option<String> {
    let mut idx = 0;
    while idx < tokens.len() && tokens[idx].starts_with('#') {
        idx += 1;
    }
    if tokens.get(idx).map(String::as_str) == Some("const") {
        return tokens.get(idx + 1).cloned();
    }
    tokens.get(idx).cloned()
}

fn lex(source: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut chars = source.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch.is_whitespace() {
            continue;
        }
        if ch == '\'' {
            let mut token = String::from("'");
            while let Some(&next) = chars.peek() {
                if next.is_ascii_alphanumeric() || next == '_' {
                    token.push(next);
                    chars.next();
                } else {
                    break;
                }
            }
            tokens.push(token);
            continue;
        }
        if ch.is_ascii_alphabetic() || ch == '_' {
            let mut token = String::new();
            token.push(ch);
            while let Some(&next) = chars.peek() {
                if next.is_ascii_alphanumeric() || next == '_' {
                    token.push(next);
                    chars.next();
                } else {
                    break;
                }
            }
            tokens.push(token);
            continue;
        }
        if ch == ':' && chars.peek() == Some(&':') {
            chars.next();
            tokens.push("::".to_string());
            continue;
        }
        if ch == '-' && chars.peek() == Some(&'>') {
            chars.next();
            tokens.push("->".to_string());
            continue;
        }
        tokens.push(ch.to_string());
    }
    tokens
}

fn join_tokens(tokens: &[String]) -> String {
    let mut out = String::new();
    for token in tokens {
        let no_space_before = matches!(token.as_str(), "," | ":" | ";" | ">" | ")" | "]" | "::");
        let no_space_after_prev = out.ends_with('<')
            || out.ends_with('(')
            || out.ends_with('[')
            || out.ends_with("::")
            || out.ends_with('!')
            || out.ends_with('&')
            || out.ends_with('\'');
        if !out.is_empty() && !no_space_before && !no_space_after_prev {
            out.push(' ');
        }
        out.push_str(token);
    }
    out
}
