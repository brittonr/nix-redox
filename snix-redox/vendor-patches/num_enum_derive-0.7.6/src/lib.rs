use proc_macro::{Delimiter, Group, TokenStream, TokenTree};

#[proc_macro_derive(IntoPrimitive, attributes(num_enum, catch_all))]
pub fn derive_into_primitive(input: TokenStream) -> TokenStream {
    match parse_enum(input) {
        Ok(info) => format!(
            "impl ::core::convert::From<{name}> for {repr} {{
                 #[inline]
                 fn from(enum_value: {name}) -> Self {{ enum_value as Self }}
             }}",
            name = info.name,
            repr = info.repr,
        )
        .parse()
        .unwrap(),
        Err(e) => compile_error(&e),
    }
}

#[proc_macro_derive(TryFromPrimitive, attributes(num_enum))]
pub fn derive_try_from_primitive(input: TokenStream) -> TokenStream {
    match parse_enum(input) {
        Ok(info) => {
            let mut arms = String::new();
            for variant in &info.variants {
                if let Some(value) = &variant.value {
                    arms.push_str(&format!(
                        "x if x == ({value} as {repr}) => ::core::result::Result::Ok(Self::{name}),",
                        value = value,
                        repr = info.repr,
                        name = variant.name,
                    ));
                }
            }
            format!(
                "impl ::num_enum::TryFromPrimitive for {name} {{
                     type Primitive = {repr};
                     type Error = ::num_enum::TryFromPrimitiveError<Self>;
                     const NAME: &'static str = stringify!({name});
                     fn try_from_primitive(number: Self::Primitive) -> ::core::result::Result<Self, Self::Error> {{
                         match number {{
                             {arms}
                             _ => ::core::result::Result::Err(::num_enum::TryFromPrimitiveError::new(number)),
                         }}
                     }}
                 }}
                 impl ::core::convert::TryFrom<{repr}> for {name} {{
                     type Error = ::num_enum::TryFromPrimitiveError<Self>;
                     #[inline]
                     fn try_from(number: {repr}) -> ::core::result::Result<Self, Self::Error> {{
                         ::num_enum::TryFromPrimitive::try_from_primitive(number)
                     }}
                 }}
                 impl ::num_enum::CannotDeriveBothFromPrimitiveAndTryFromPrimitive for {name} {{}}",
                name = info.name,
                repr = info.repr,
                arms = arms,
            )
            .parse()
            .unwrap()
        }
        Err(e) => compile_error(&e),
    }
}

#[proc_macro_derive(FromPrimitive, attributes(num_enum, default, catch_all))]
pub fn derive_from_primitive(input: TokenStream) -> TokenStream {
    match parse_enum(input) {
        Ok(info) => {
            let default = info
                .variants
                .iter()
                .find(|v| v.is_default)
                .map(|v| format!("Self::{}", v.name))
                .or_else(|| info.variants.first().map(|v| format!("Self::{}", v.name)))
                .unwrap_or_else(|| "panic!(\"empty enum\")".to_string());
            let mut arms = String::new();
            for variant in &info.variants {
                if let Some(value) = &variant.value {
                    arms.push_str(&format!(
                        "x if x == ({value} as {repr}) => Self::{name},",
                        value = value,
                        repr = info.repr,
                        name = variant.name,
                    ));
                }
            }
            format!(
                "impl ::num_enum::FromPrimitive for {name} {{
                     type Primitive = {repr};
                     fn from_primitive(number: Self::Primitive) -> Self {{
                         match number {{ {arms} _ => {default}, }}
                     }}
                 }}
                 impl ::core::convert::From<{repr}> for {name} {{
                     #[inline]
                     fn from(number: {repr}) -> Self {{ ::num_enum::FromPrimitive::from_primitive(number) }}
                 }}
                 impl ::num_enum::CannotDeriveBothFromPrimitiveAndTryFromPrimitive for {name} {{}}",
                name = info.name,
                repr = info.repr,
                arms = arms,
                default = default,
            )
            .parse()
            .unwrap()
        }
        Err(e) => compile_error(&e),
    }
}

#[proc_macro_derive(UnsafeFromPrimitive, attributes(num_enum))]
pub fn derive_unsafe_from_primitive(input: TokenStream) -> TokenStream {
    match parse_enum(input) {
        Ok(info) => format!(
            "impl ::num_enum::UnsafeFromPrimitive for {name} {{
                 type Primitive = {repr};
                 unsafe fn unchecked_transmute_from(number: Self::Primitive) -> Self {{
                     ::core::mem::transmute(number)
                 }}
             }}",
            name = info.name,
            repr = info.repr,
        )
        .parse()
        .unwrap(),
        Err(e) => compile_error(&e),
    }
}

#[proc_macro_derive(Default, attributes(num_enum, default))]
pub fn derive_default(input: TokenStream) -> TokenStream {
    match parse_enum(input) {
        Ok(info) => {
            let default = info
                .variants
                .iter()
                .find(|v| v.is_default)
                .map(|v| v.name.clone())
                .or_else(|| info.variants.first().map(|v| v.name.clone()))
                .unwrap_or_else(|| "__Empty".to_string());
            format!(
                "impl ::core::default::Default for {name} {{
                     #[inline]
                     fn default() -> Self {{ Self::{default} }}
                 }}",
                name = info.name,
                default = default,
            )
            .parse()
            .unwrap()
        }
        Err(e) => compile_error(&e),
    }
}

struct EnumInfo {
    name: String,
    repr: String,
    variants: Vec<Variant>,
}

struct Variant {
    name: String,
    value: Option<String>,
    is_default: bool,
}

fn parse_enum(input: TokenStream) -> Result<EnumInfo, String> {
    let mut repr = None;
    let mut saw_default_attr = false;
    let mut tokens = input.into_iter().peekable();
    let mut name = None;
    let mut body = None;

    while let Some(tt) = tokens.next() {
        match tt {
            TokenTree::Punct(p) if p.as_char() == '#' => {
                if let Some(TokenTree::Group(g)) = tokens.next() {
                    let text = g.stream().to_string();
                    if text.starts_with("repr") {
                        if let Some(inner) = first_group(g.stream()) {
                            repr = Some(inner.stream().to_string().replace(' ', ""));
                        }
                    } else if text.contains("default") {
                        saw_default_attr = true;
                    }
                }
            }
            TokenTree::Ident(id) if id.to_string() == "enum" => {
                if let Some(TokenTree::Ident(n)) = tokens.next() {
                    name = Some(n.to_string());
                }
                for next in tokens.by_ref() {
                    if let TokenTree::Group(g) = next {
                        if g.delimiter() == Delimiter::Brace {
                            body = Some(g.stream());
                            break;
                        }
                    }
                }
                break;
            }
            _ => {
                saw_default_attr = false;
            }
        }
    }

    let name = name.ok_or_else(|| "num_enum_derive shim: enum name not found".to_string())?;
    let repr = repr.unwrap_or_else(|| "isize".to_string());
    let body = body.ok_or_else(|| "num_enum_derive shim: enum body not found".to_string())?;
    let variants = parse_variants(body, saw_default_attr);
    Ok(EnumInfo { name, repr, variants })
}

fn first_group(stream: TokenStream) -> Option<Group> {
    stream.into_iter().find_map(|tt| match tt {
        TokenTree::Group(g) => Some(g),
        _ => None,
    })
}

fn parse_variants(body: TokenStream, mut pending_default: bool) -> Vec<Variant> {
    let mut variants = Vec::new();
    let mut iter = body.into_iter().peekable();
    while let Some(tt) = iter.next() {
        match tt {
            TokenTree::Punct(p) if p.as_char() == '#' => {
                if let Some(TokenTree::Group(g)) = iter.next() {
                    let text = g.stream().to_string();
                    if text.contains("default") || text.contains("num_enum") && text.contains("default") {
                        pending_default = true;
                    }
                }
            }
            TokenTree::Ident(id) => {
                let variant_name = id.to_string();
                let mut value = None;
                if let Some(TokenTree::Punct(p)) = iter.peek() {
                    if p.as_char() == '=' {
                        iter.next();
                        let mut expr = String::new();
                        let mut depth = 0i32;
                        while let Some(next) = iter.peek() {
                            match next {
                                TokenTree::Punct(p) if p.as_char() == ',' && depth == 0 => break,
                                TokenTree::Group(_) => {
                                    if !expr.is_empty() { expr.push(' '); }
                                    let tt = iter.next().unwrap();
                                    expr.push_str(&tt.to_string());
                                }
                                TokenTree::Punct(p) if "([{".contains(p.as_char()) => { depth += 1; let tt=iter.next().unwrap(); expr.push_str(&tt.to_string()); }
                                TokenTree::Punct(p) if ")] }".contains(p.as_char()) => { depth -= 1; let tt=iter.next().unwrap(); expr.push_str(&tt.to_string()); }
                                _ => {
                                    let tt = iter.next().unwrap();
                                    if !expr.is_empty() { expr.push(' '); }
                                    expr.push_str(&tt.to_string());
                                }
                            }
                        }
                        value = Some(expr.trim().to_string());
                    }
                }
                // Skip tuple/struct variant payloads; current self-hosting uses fieldless repr enums.
                if let Some(TokenTree::Group(_)) = iter.peek() {
                    iter.next();
                }
                variants.push(Variant { name: variant_name, value, is_default: pending_default });
                pending_default = false;
            }
            _ => {}
        }
    }
    variants
}

fn compile_error(msg: &str) -> TokenStream {
    format!("compile_error!({:?});", msg).parse().unwrap()
}
