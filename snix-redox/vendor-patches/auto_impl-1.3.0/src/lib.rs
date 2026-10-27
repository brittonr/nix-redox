//! Minimal `auto_impl` replacement for the Redox guest self-compile.
//!
//! `#[auto_impl]` runs *after* `#[async_trait]`, so the trait methods it sees
//! are already rewritten to `fn(..) -> Pin<Box<dyn Future<..>>>`. Instead of
//! hardcoding signatures, this shim copies each required method signature
//! verbatim from the input trait and forwards the call to the wrapped value.
//! Methods with default bodies are skipped; the trait default applies and calls
//! the forwarding impls.

use proc_macro::TokenStream;

#[proc_macro_attribute]
pub fn auto_impl(_args: TokenStream, input: TokenStream) -> TokenStream {
    let src = input.to_string();
    let Some((trait_name, body)) = split_trait(&src) else {
        return input;
    };

    let mut out = String::new();
    for method in plain_methods(body) {
        for target in ["std::sync::Arc<T>", "Box<T>", "&T", "&mut T"] {
            out.push_str(&format!(
                "impl<T: {trait_name} + ?Sized> {trait_name} for {target} {{ {sig} {{ (**self).{name}({args}) }} }}\n",
                sig = method.sig,
                name = method.name,
                args = method.args,
            ));
        }
    }

    format!("{src}\n{out}").parse().unwrap_or(input)
}

struct Method {
    sig: String,
    name: String,
    args: String,
}

fn split_trait(src: &str) -> Option<(&str, &str)> {
    // Doc comments can contain the word "trait"; the definition is last.
    let trait_pos = src.rfind("trait ")?;
    let after = &src[trait_pos + "trait ".len()..];
    let name_end = after.find(|c: char| !(c.is_alphanumeric() || c == '_'))?;
    let name = &after[..name_end];
    let open = src[trait_pos..].find('{')? + trait_pos;
    let close = matching(src, open, '{', '}')?;
    Some((name, &src[open + 1..close]))
}

fn plain_methods(body: &str) -> Vec<Method> {
    let bytes = body.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
    let mut depth = 0isize;
    while i < bytes.len() {
        match bytes[i] {
            b'{' => {
                depth += 1;
                i += 1;
                continue;
            }
            b'}' => {
                depth -= 1;
                i += 1;
                continue;
            }
            _ => {}
        }
        if depth == 0 && body[i..].starts_with("fn ") {
            let start = i;
            let name_end = body[start + 3..]
                .find(|c: char| !(c.is_alphanumeric() || c == '_'))
                .map(|off| start + 3 + off)
                .unwrap_or(body.len());
            let name = body[start + 3..name_end].to_string();
            let Some(open_paren) = body[name_end..].find('(').map(|off| name_end + off) else {
                break;
            };
            let Some(close_paren) = matching(body, open_paren, '(', ')') else {
                break;
            };
            let args = forward_args(&body[open_paren + 1..close_paren]);
            // Find the signature terminator: `;` for required methods or the
            // default body. Default methods are left to the trait default.
            let mut j = close_paren + 1;
            let mut angle = 0isize;
            let mut paren = 0isize;
            let mut terminator = None;
            while j < bytes.len() {
                if bytes[j] == b'-' && bytes.get(j + 1) == Some(&b'>') {
                    j += 2;
                    continue;
                }
                match bytes[j] {
                    b'<' => angle += 1,
                    b'>' => angle -= 1,
                    b'(' => paren += 1,
                    b')' => paren -= 1,
                    b';' if angle == 0 && paren == 0 => {
                        terminator = Some((j, ';'));
                        break;
                    }
                    b'{' if angle == 0 && paren == 0 => {
                        let Some(end) = matching(body, j, '{', '}') else {
                            break;
                        };
                        terminator = Some((end, '}'));
                        break;
                    }
                    _ => {}
                }
                j += 1;
            }
            let Some((end, kind)) = terminator else {
                break;
            };
            if kind == ';' {
                out.push(Method {
                    sig: body[start..end].trim().to_string(),
                    name,
                    args,
                });
            }
            i = end + 1;
            continue;
        }
        i += 1;
    }
    out
}

fn forward_args(args: &str) -> String {
    let mut out = Vec::new();
    for part in split_top_level(args, ',') {
        let part = part.trim();
        if part.is_empty() || part.contains("self") {
            continue;
        }
        let pattern = match part.find(':') {
            Some(colon) => part[..colon].trim(),
            None => part,
        };
        let pattern = pattern.strip_prefix("mut ").unwrap_or(pattern).trim();
        out.push(pattern.to_string());
    }
    out.join(", ")
}

fn split_top_level(input: &str, separator: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut round = 0isize;
    let mut square = 0isize;
    let mut curly = 0isize;
    let mut angle = 0isize;
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        // `->` is not an angle bracket pair.
        if c == '-' && chars.peek() == Some(&'>') {
            current.push(c);
            current.push(chars.next().unwrap());
            continue;
        }
        match c {
            '(' => round += 1,
            ')' => round -= 1,
            '[' => square += 1,
            ']' => square -= 1,
            '{' => curly += 1,
            '}' => curly -= 1,
            '<' => angle += 1,
            '>' => angle -= 1,
            _ => {}
        }
        if c == separator && round == 0 && square == 0 && curly == 0 && angle == 0 {
            out.push(current.trim().to_string());
            current.clear();
        } else {
            current.push(c);
        }
    }
    if !current.trim().is_empty() {
        out.push(current.trim().to_string());
    }
    out
}

fn matching(input: &str, open: usize, open_ch: char, close_ch: char) -> Option<usize> {
    let mut depth = 0isize;
    for (i, c) in input[open..].char_indices() {
        if c == open_ch {
            depth += 1;
        } else if c == close_ch {
            depth -= 1;
            if depth == 0 {
                return Some(open + i);
            }
        }
    }
    None
}
