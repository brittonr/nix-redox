extern crate proc_macro;

use proc_macro::{Delimiter, Group, Spacing, TokenStream, TokenTree};

#[proc_macro_derive(Message, attributes(prost))]
pub fn message(input: TokenStream) -> TokenStream {
    let item = Item::parse(input);
    let Some(name) = item.name else { return TokenStream::new(); };
    let fields = item.fields;
    let defaults = fields
        .iter()
        .map(|f| format!("{}: ::core::default::Default::default()", f.name))
        .collect::<Vec<_>>()
        .join(", ");
    let accessors = accessor_methods(&name, &fields);
    let expanded = format!(
        r#"
impl {name} {{
{accessors}
}}
impl ::core::default::Default for {name} {{
    fn default() -> Self {{ Self {{ {defaults} }} }}
}}
impl ::core::fmt::Debug for {name} {{
    fn fmt(&self, f: &mut ::core::fmt::Formatter<'_>) -> ::core::fmt::Result {{
        f.write_str(stringify!({name}))
    }}
}}
impl ::prost::Message for {name} {{
    fn encode_raw(&self, _buf: &mut impl ::prost::bytes::BufMut) {{}}
    fn merge_field(
        &mut self,
        tag: u32,
        wire_type: ::prost::encoding::wire_type::WireType,
        buf: &mut impl ::prost::bytes::Buf,
        ctx: ::prost::encoding::DecodeContext,
    ) -> ::core::result::Result<(), ::prost::DecodeError> {{
        ::prost::encoding::skip_field(wire_type, tag, buf, ctx)
    }}
    fn encoded_len(&self) -> usize {{ 0 }}
    fn clear(&mut self) {{ *self = ::core::default::Default::default(); }}
}}
"#
    );
    expanded.parse().unwrap_or_default()
}

#[proc_macro_derive(Oneof, attributes(prost))]
pub fn oneof(input: TokenStream) -> TokenStream {
    let item = Item::parse(input);
    let Some(name) = item.name else { return TokenStream::new(); };
    let expanded = format!(
        r#"
impl {name} {{
    pub fn encode(&self, _buf: &mut impl ::prost::bytes::BufMut) {{}}
    pub fn merge(
        field: &mut ::core::option::Option<{name}>,
        tag: u32,
        wire_type: ::prost::encoding::wire_type::WireType,
        buf: &mut impl ::prost::bytes::Buf,
        ctx: ::prost::encoding::DecodeContext,
    ) -> ::core::result::Result<(), ::prost::DecodeError> {{
        *field = ::core::option::Option::None;
        ::prost::encoding::skip_field(wire_type, tag, buf, ctx)
    }}
    pub fn encoded_len(&self) -> usize {{ 0 }}
}}
impl ::core::fmt::Debug for {name} {{
    fn fmt(&self, f: &mut ::core::fmt::Formatter<'_>) -> ::core::fmt::Result {{
        f.write_str(stringify!({name}))
    }}
}}
"#
    );
    expanded.parse().unwrap_or_default()
}

#[proc_macro_derive(Enumeration, attributes(prost))]
pub fn enumeration(input: TokenStream) -> TokenStream {
    let item = Item::parse(input);
    let Some(name) = item.name else { return TokenStream::new(); };
    let variants = item.variants;
    let default_variant = variants
        .first()
        .map(|(v, _)| v.as_str())
        .unwrap_or("__InvalidDefaultVariant");
    let is_valid_arms = variants
        .iter()
        .filter_map(|(_, val)| val.as_ref())
        .map(|v| format!("{v} => true"))
        .collect::<Vec<_>>()
        .join(",");
    let from_arms = variants
        .iter()
        .filter_map(|(variant, val)| val.as_ref().map(|v| (variant, v)))
        .map(|(variant, v)| format!("{v} => ::core::option::Option::Some(Self::{variant})"))
        .collect::<Vec<_>>()
        .join(",");
    let try_arms = variants
        .iter()
        .filter_map(|(variant, val)| val.as_ref().map(|v| (variant, v)))
        .map(|(variant, v)| format!("{v} => ::core::result::Result::Ok(Self::{variant})"))
        .collect::<Vec<_>>()
        .join(",");
    let expanded = format!(
        r#"
impl {name} {{
    pub fn is_valid(value: i32) -> bool {{ match value {{ {is_valid_arms}, _ => false }} }}
    #[deprecated = "Use the TryFrom<i32> implementation instead"]
    pub fn from_i32(value: i32) -> ::core::option::Option<Self> {{ match value {{ {from_arms}, _ => ::core::option::Option::None }} }}
}}
impl ::core::default::Default for {name} {{
    fn default() -> Self {{ Self::{default_variant} }}
}}
impl ::core::convert::From<{name}> for i32 {{
    fn from(value: {name}) -> i32 {{ value as i32 }}
}}
impl ::core::convert::TryFrom<i32> for {name} {{
    type Error = ::prost::UnknownEnumValue;
    fn try_from(value: i32) -> ::core::result::Result<Self, Self::Error> {{
        match value {{ {try_arms}, _ => ::core::result::Result::Err(::prost::UnknownEnumValue(value)) }}
    }}
}}
"#
    );
    expanded.parse().unwrap_or_default()
}

struct Item {
    name: Option<String>,
    fields: Vec<Field>,
    variants: Vec<(String, Option<String>)>,
}

struct Field {
    name: String,
    ty: String,
}

impl Item {
    fn parse(input: TokenStream) -> Self {
        let mut saw_kind: Option<String> = None;
        let mut name = None;
        let mut body: Option<Group> = None;
        let mut iter = input.into_iter().peekable();
        while let Some(tt) = iter.next() {
            match tt {
                TokenTree::Ident(id) if id.to_string() == "struct" || id.to_string() == "enum" => {
                    saw_kind = Some(id.to_string());
                    for tt in iter.by_ref() {
                        if let TokenTree::Ident(n) = tt {
                            name = Some(n.to_string());
                            break;
                        }
                    }
                }
                TokenTree::Group(g) if g.delimiter() == Delimiter::Brace => {
                    body = Some(g);
                    break;
                }
                _ => {}
            }
        }
        let body_stream = body.map(|g| g.stream()).unwrap_or_default();
        let fields = if saw_kind.as_deref() == Some("struct") {
            parse_struct_fields(body_stream.clone())
        } else {
            Vec::new()
        };
        let variants = if saw_kind.as_deref() == Some("enum") {
            parse_enum_variants(body_stream)
        } else {
            Vec::new()
        };
        Self { name, fields, variants }
    }
}

fn parse_struct_fields(stream: TokenStream) -> Vec<Field> {
    let mut out = Vec::new();
    let mut iter = stream.into_iter().peekable();
    while let Some(tt) = iter.next() {
        match tt {
            TokenTree::Punct(p) if p.as_char() == '#' => {
                let _ = iter.next();
            }
            TokenTree::Ident(id) => {
                let s = id.to_string();
                if s == "pub" {
                    continue;
                }
                let mut field = s;
                if field == "r" {
                    if let Some(TokenTree::Punct(p)) = iter.peek() {
                        if p.as_char() == '#' {
                            let _ = iter.next();
                            if let Some(TokenTree::Ident(raw)) = iter.next() {
                                field = format!("r#{}", raw);
                            }
                        }
                    }
                }
                if let Some(TokenTree::Punct(p)) = iter.peek() {
                    if p.as_char() == ':' && p.spacing() == Spacing::Alone {
                        let _ = iter.next();
                        let ty = collect_type_until_comma(&mut iter);
                        out.push(Field { name: field, ty });
                    }
                }
            }
            _ => {}
        }
    }
    out
}

fn collect_type_until_comma<I>(iter: &mut std::iter::Peekable<I>) -> String
where
    I: Iterator<Item = TokenTree>,
{
    let mut s = String::new();
    let mut depth = 0usize;
    while let Some(tt) = iter.peek() {
        match tt {
            TokenTree::Punct(p) if p.as_char() == ',' && depth == 0 => break,
            TokenTree::Punct(p) if p.as_char() == '<' => {
                depth += 1;
                s.push_str(&iter.next().unwrap().to_string());
            }
            TokenTree::Punct(p) if p.as_char() == '>' => {
                depth = depth.saturating_sub(1);
                s.push_str(&iter.next().unwrap().to_string());
            }
            _ => s.push_str(&iter.next().unwrap().to_string()),
        }
    }
    s
}

fn accessor_methods(type_name: &str, fields: &[Field]) -> String {
    let mut out = Vec::new();
    for f in fields {
        let compact_ty = f.ty.replace(' ', "");
        let name = &f.name;
        if type_name == "FieldDescriptorProto" && name == "label" {
            out.push(format!("    pub fn {name}(&self) -> field_descriptor_proto::Label {{ ::core::convert::TryFrom::try_from(self.{name}.unwrap_or(field_descriptor_proto::Label::Optional as i32)).unwrap_or(field_descriptor_proto::Label::Optional) }}"));
        } else if type_name == "FieldDescriptorProto" && name == "r#type" {
            out.push(format!("    pub fn {name}(&self) -> field_descriptor_proto::Type {{ ::core::convert::TryFrom::try_from(self.{name}.unwrap_or(field_descriptor_proto::Type::Double as i32)).unwrap_or(field_descriptor_proto::Type::Double) }}"));
        } else if compact_ty.contains("Option") && compact_ty.contains("String") {
            out.push(format!("    pub fn {name}(&self) -> &str {{ self.{name}.as_deref().unwrap_or(\"\") }}"));
        } else if compact_ty.contains("Option") && compact_ty.contains("bool") {
            out.push(format!("    pub fn {name}(&self) -> bool {{ self.{name}.unwrap_or(false) }}"));
        } else if compact_ty.contains("Option") && compact_ty.contains("i32") {
            out.push(format!("    pub fn {name}(&self) -> i32 {{ self.{name}.unwrap_or(0) }}"));
        }
    }
    out.join("\n")
}

fn parse_enum_variants(stream: TokenStream) -> Vec<(String, Option<String>)> {
    let mut out = Vec::new();
    let mut iter = stream.into_iter().peekable();
    while let Some(tt) = iter.next() {
        match tt {
            TokenTree::Punct(p) if p.as_char() == '#' => {
                let _ = iter.next();
            }
            TokenTree::Ident(id) => {
                let variant = id.to_string();
                let mut value = None;
                loop {
                    match iter.peek() {
                        Some(TokenTree::Punct(p)) if p.as_char() == '=' => {
                            let _ = iter.next();
                            value = next_literal_or_number(&mut iter);
                        }
                        Some(TokenTree::Punct(p)) if p.as_char() == ',' => {
                            let _ = iter.next();
                            break;
                        }
                        Some(_) => { let _ = iter.next(); }
                        None => break,
                    }
                }
                out.push((variant, value));
            }
            _ => {}
        }
    }
    out
}

fn next_literal_or_number<I>(iter: &mut std::iter::Peekable<I>) -> Option<String>
where
    I: Iterator<Item = TokenTree>,
{
    let mut s = String::new();
    while let Some(tt) = iter.peek() {
        match tt {
            TokenTree::Punct(p) if p.as_char() == ',' => break,
            _ => {
                s.push_str(&iter.next().unwrap().to_string());
            }
        }
    }
    if s.is_empty() { None } else { Some(s) }
}
