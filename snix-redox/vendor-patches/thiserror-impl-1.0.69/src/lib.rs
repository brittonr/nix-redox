extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro_derive(Error, attributes(error, from, source, backtrace, diagnostic))]
pub fn derive_error(input: TokenStream) -> TokenStream {
    let src = input.to_string();
    match expand_error(&src) {
        Ok(out) => out.parse().unwrap_or_else(|_| TokenStream::new()),
        Err(_) => TokenStream::new(),
    }
}

fn expand_error(src: &str) -> Result<String, ()> {
    let kind_pos = find_word(src, "enum").or_else(|| find_word(src, "struct")).ok_or(())?;
    let is_enum = src[kind_pos..].starts_with("enum");
    let after_kind = kind_pos + if is_enum { 4 } else { 6 };
    let rest = &src[after_kind..];
    let (name, name_end_rel) = parse_ident(rest).ok_or(())?;
    let name_end = after_kind + name_end_rel;
    let body_start = find_top_level_body(src, name_end).ok_or(())?;
    let header = src[name_end..body_start].trim();
    let (impl_generics, ty_generics, where_clause) = parse_generics_and_where(header);

    let mut out = String::new();
    out.push_str(&format!(
        "impl {impl_generics} ::std::fmt::Display for {name}{ty_generics} {where_clause} {{ fn fmt(&self, f: &mut ::std::fmt::Formatter<'_>) -> ::std::fmt::Result {{ ::std::write!(f, \"{{:?}}\", self) }} }}\n",
    ));
    out.push_str(&format!(
        "impl {impl_generics} ::std::error::Error for {name}{ty_generics} {where_clause} {{}}\n",
    ));

    if is_enum {
        if let Some((body, _)) = balanced_slice(src, body_start, '{', '}') {
            for impl_from in enum_from_impls(&name, &impl_generics, &ty_generics, &where_clause, body) {
                out.push_str(&impl_from);
            }
        }
    } else if let Some(impl_from) = struct_from_impl(&name, &impl_generics, &ty_generics, &where_clause, src, body_start) {
        out.push_str(&impl_from);
    }
    Ok(out)
}

fn find_word(s: &str, word: &str) -> Option<usize> {
    let bytes = s.as_bytes();
    let w = word.as_bytes();
    let mut i = 0;
    while i + w.len() <= bytes.len() {
        if &bytes[i..i + w.len()] == w {
            let before = i == 0 || !is_ident_byte(bytes[i - 1]);
            let after = i + w.len() == bytes.len() || !is_ident_byte(bytes[i + w.len()]);
            if before && after { return Some(i); }
        }
        i += 1;
    }
    None
}

fn parse_ident(s: &str) -> Option<(String, usize)> {
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() && bytes[i].is_ascii_whitespace() { i += 1; }
    let start = i;
    if i >= bytes.len() || !(bytes[i].is_ascii_alphabetic() || bytes[i] == b'_') { return None; }
    i += 1;
    while i < bytes.len() && is_ident_byte(bytes[i]) { i += 1; }
    Some((s[start..i].to_string(), i))
}

fn is_ident_byte(b: u8) -> bool { b.is_ascii_alphanumeric() || b == b'_' }

fn find_top_level_body(s: &str, start: usize) -> Option<usize> {
    let mut angle = 0i32;
    let mut paren = 0i32;
    let mut bracket = 0i32;
    for (off, ch) in s[start..].char_indices() {
        match ch {
            '<' => angle += 1,
            '>' if angle > 0 => angle -= 1,
            '(' => paren += 1,
            ')' if paren > 0 => paren -= 1,
            '[' => bracket += 1,
            ']' if bracket > 0 => bracket -= 1,
            '{' if angle == 0 && paren == 0 && bracket == 0 => return Some(start + off),
            ';' if angle == 0 && paren == 0 && bracket == 0 => return Some(start + off),
            _ => {}
        }
    }
    None
}

fn balanced_slice(s: &str, open_pos: usize, open: char, close: char) -> Option<(&str, usize)> {
    let mut depth = 0i32;
    let mut body_start = None;
    for (off, ch) in s[open_pos..].char_indices() {
        let pos = open_pos + off;
        if ch == open {
            depth += 1;
            if body_start.is_none() { body_start = Some(pos + ch.len_utf8()); }
        } else if ch == close {
            depth -= 1;
            if depth == 0 { return Some((&s[body_start?..pos], pos)); }
        }
    }
    None
}

fn parse_generics_and_where(header: &str) -> (String, String, String) {
    let h = header.trim();
    let mut generics = String::new();
    let mut rest = h;
    if h.starts_with('<') {
        if let Some(end) = matching_angle(h, 0) {
            generics = h[..=end].to_string();
            rest = h[end + 1..].trim();
        }
    }
    let where_clause = if rest.starts_with("where") { rest.to_string() } else { String::new() };
    let type_args = if generics.is_empty() { String::new() } else { generic_type_args(&generics) };
    let impl_generics = generics;
    let where_clause = if where_clause.is_empty() { String::new() } else { format!(" {}", where_clause) };
    (impl_generics, type_args, where_clause)
}

fn matching_angle(s: &str, start: usize) -> Option<usize> {
    let mut depth = 0i32;
    for (off, ch) in s[start..].char_indices() {
        match ch {
            '<' => depth += 1,
            '>' => { depth -= 1; if depth == 0 { return Some(start + off); } }
            _ => {}
        }
    }
    None
}

fn generic_type_args(generics: &str) -> String {
    let inner = generics.trim().trim_start_matches('<').trim_end_matches('>');
    let args: Vec<String> = split_top_level(inner, ',').into_iter().filter_map(|p| {
        let p = p.trim();
        if p.is_empty() { return None; }
        let p = p.strip_prefix("const ").unwrap_or(p).trim();
        let cut = find_first_top_level(p, &[':', '=']).unwrap_or(p.len());
        let name = p[..cut].trim();
        if name.is_empty() { None } else { Some(name.to_string()) }
    }).collect();
    if args.is_empty() { String::new() } else { format!("<{}>", args.join(", ")) }
}

fn split_top_level(s: &str, sep: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut paren = 0i32; let mut brace = 0i32; let mut bracket = 0i32; let mut angle = 0i32;
    let chars: Vec<(usize, char)> = s.char_indices().collect();
    for (idx, ch) in chars {
        match ch {
            '(' => paren += 1, ')' if paren > 0 => paren -= 1,
            '{' => brace += 1, '}' if brace > 0 => brace -= 1,
            '[' => bracket += 1, ']' if bracket > 0 => bracket -= 1,
            '<' => angle += 1, '>' if angle > 0 => angle -= 1,
            _ => {}
        }
        if ch == sep && paren == 0 && brace == 0 && bracket == 0 && angle == 0 {
            out.push(s[start..idx].to_string());
            start = idx + ch.len_utf8();
        }
    }
    out.push(s[start..].to_string());
    out
}

fn find_first_top_level(s: &str, needles: &[char]) -> Option<usize> {
    let mut paren = 0i32; let mut brace = 0i32; let mut bracket = 0i32; let mut angle = 0i32;
    for (idx, ch) in s.char_indices() {
        match ch {
            '(' => paren += 1, ')' if paren > 0 => paren -= 1,
            '{' => brace += 1, '}' if brace > 0 => brace -= 1,
            '[' => bracket += 1, ']' if bracket > 0 => bracket -= 1,
            '<' => angle += 1, '>' if angle > 0 => angle -= 1,
            _ => {}
        }
        if needles.contains(&ch) && paren == 0 && brace == 0 && bracket == 0 && angle == 0 {
            return Some(idx);
        }
    }
    None
}

fn enum_from_impls(name: &str, impl_generics: &str, ty_generics: &str, where_clause: &str, body: &str) -> Vec<String> {
    let mut out = Vec::new();
    for raw in split_top_level(body, ',') {
        let variant_src = raw.trim();
        if variant_src.is_empty() { continue; }
        let transparent = compact(variant_src).contains("#[error(transparent)]");
        let cleaned = strip_leading_attrs(variant_src).trim().to_string();
        let Some((variant, v_end)) = parse_ident(&cleaned) else { continue; };
        let rest = cleaned[v_end..].trim();
        if rest.starts_with('(') {
            if let Some((fields, _)) = balanced_slice(rest, 0, '(', ')') {
                let parts = split_top_level(fields, ',');
                if parts.len() == 1 {
                    let f = parts[0].trim();
                    if transparent || compact(f).contains("#[from]") {
                        let ty = strip_leading_attrs(f).trim().to_string();
                        if !ty.is_empty() {
                            out.push(format!("impl {impl_generics} ::std::convert::From<{ty}> for {name}{ty_generics} {where_clause} {{ fn from(error: {ty}) -> Self {{ {name}::{variant}(error) }} }}\n"));
                        }
                    }
                }
            }
        } else if rest.starts_with('{') {
            if let Some((fields, _)) = balanced_slice(rest, 0, '{', '}') {
                let parts = split_top_level(fields, ',');
                if parts.len() == 1 {
                    let f = parts[0].trim();
                    if transparent || compact(f).contains("#[from]") {
                        let no_attrs = strip_leading_attrs(f);
                        if let Some(colon) = find_first_top_level(&no_attrs, &[':']) {
                            let field_name = no_attrs[..colon].trim();
                            let ty = no_attrs[colon + 1..].trim();
                            if !field_name.is_empty() && !ty.is_empty() {
                                out.push(format!("impl {impl_generics} ::std::convert::From<{ty}> for {name}{ty_generics} {where_clause} {{ fn from(error: {ty}) -> Self {{ {name}::{variant} {{ {field_name}: error }} }} }}\n"));
                            }
                        }
                    }
                }
            }
        }
    }
    out
}

fn struct_from_impl(name: &str, impl_generics: &str, ty_generics: &str, where_clause: &str, src: &str, body_start: usize) -> Option<String> {
    let body = if src[body_start..].starts_with('{') {
        balanced_slice(src, body_start, '{', '}')?.0.to_string()
    } else if src[body_start..].starts_with('(') {
        balanced_slice(src, body_start, '(', ')')?.0.to_string()
    } else { return None; };
    let fields = split_top_level(&body, ',');
    if fields.len() != 1 { return None; }
    let f = fields[0].trim();
    if !compact(f).contains("#[from]") { return None; }
    let no_attrs = strip_leading_attrs(f);
    if src[body_start..].starts_with('(') {
        let ty = no_attrs.trim();
        Some(format!("impl {impl_generics} ::std::convert::From<{ty}> for {name}{ty_generics} {where_clause} {{ fn from(error: {ty}) -> Self {{ {name}(error) }} }}\n"))
    } else {
        let colon = find_first_top_level(&no_attrs, &[':'])?;
        let field_name = no_attrs[..colon].trim();
        let ty = no_attrs[colon + 1..].trim();
        Some(format!("impl {impl_generics} ::std::convert::From<{ty}> for {name}{ty_generics} {where_clause} {{ fn from(error: {ty}) -> Self {{ {name} {{ {field_name}: error }} }} }}\n"))
    }
}

fn strip_leading_attrs(s: &str) -> String {
    let mut out = s.trim().to_string();
    loop {
        let t = out.trim_start();
        if !t.starts_with('#') { return t.to_string(); }
        let Some(bracket_pos) = t.find('[') else { return t.to_string(); };
        let prefix_len = t.len() - t[bracket_pos..].len();
        if let Some((_, end)) = balanced_slice(t, prefix_len, '[', ']') {
            out = t[end + 1..].trim_start().to_string();
        } else { return t.to_string(); }
    }
}

fn compact(s: &str) -> String { s.chars().filter(|c| !c.is_whitespace()).collect() }
