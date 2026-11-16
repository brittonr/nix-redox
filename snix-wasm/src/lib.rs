// SPDX-License-Identifier: GPL-3.0-or-later
//! Direct Snix evaluation, not a Redox process or a store/build service.
use std::{collections::BTreeMap, ffi::{OsStr, OsString}, fmt::{self, Write as _}, io, path::{Path, PathBuf}};
use serde::{Deserialize, Serialize};
use snix_eval::{EvalIO, EvalMode, Evaluation, FileType, SourceCode};
use wasm_bindgen::prelude::*;

pub const REVISION: &str = "34604636d7e3adbad6f7f909c98bb493f26855f9";
pub const SOURCE_LIMIT: usize = 64 * 1024;
const OUTPUT_LIMIT: usize = 16 * 1024;
const DIAGNOSTIC_LIMIT: usize = 16;
const MESSAGE_LIMIT: usize = 2048;
const ROOT: &str = "/playground/v1";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request { id: u32, source: String }

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Diagnostic {
    severity: &'static str,
    message: String,
    source: String,
    line: usize,
    column: usize,
    end_line: usize,
    end_column: usize,
}

#[derive(Serialize)]
struct Response {
    protocol: u8,
    id: u32,
    revision: &'static str,
    ok: bool,
    value: Option<String>,
    truncated: bool,
    diagnostics: Vec<Diagnostic>,
    // Tracing is deliberately unavailable, not silently collected without bounds.
    traces: Vec<String>,
}

/// Stops formatting at a UTF-8 boundary without allocating the entire value.
struct Bounded { text: String, limit: usize, truncated: bool }
impl Bounded {
    fn new(limit: usize) -> Self { Self { text: String::new(), limit, truncated: false } }
}
impl fmt::Write for Bounded {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        let available = self.limit - self.text.len();
        let mut end = text.len().min(available);
        while !text.is_char_boundary(end) { end -= 1; }
        self.text.push_str(&text[..end]);
        if end < text.len() { self.truncated = true; return Err(fmt::Error); }
        Ok(())
    }
}

fn unavailable(path: &Path) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied,
        format!("unsupported I/O outside the bundled {ROOT} source tree: {}", path.display()))
}

/// Lexical POSIX paths only. No host filesystem, symlinks, percent decoding,
/// URL handling, environment expansion, or asynchronous fetching during EvalIO.
fn normalize(path: &Path) -> io::Result<PathBuf> {
    // wasm32-unknown-unknown does not provide Unix Path::is_absolute or
    // Component::RootDir semantics. This is an explicit virtual POSIX tree.
    let raw = path.to_str().ok_or_else(|| unavailable(path))?;
    if !raw.starts_with('/') { return Err(unavailable(path)); }
    let mut normalized = String::with_capacity(raw.len());
    normalized.push('/');
    for part in raw.split('/') {
        match part {
            "" | "." => {},
            ".." => {
                if normalized.len() == 1 { return Err(unavailable(path)); }
                normalized.truncate(normalized.rfind('/').unwrap().max(1));
            },
            name => {
                if normalized.len() > 1 { normalized.push('/'); }
                normalized.push_str(name);
            },
        }
    }
    if !normalized.strip_prefix(ROOT).is_some_and(|rest| rest.is_empty() || rest.starts_with('/')) {
        return Err(unavailable(path));
    }
    Ok(normalized.into())
}

const FILES: &[(&str, &str)] = &[
    ("/playground/v1/lib/math.nix", include_str!("../fixtures/v1/lib/math.nix")),
];
struct BundledIO;
impl BundledIO {
    fn kind(&self, path: &Path) -> io::Result<FileType> {
        let name = path.to_str().ok_or_else(|| unavailable(path))?;
        if FILES.iter().any(|(file, _)| *file == name) { return Ok(FileType::Regular); }
        if FILES.iter().any(|(file, _)| file.strip_prefix(name).is_some_and(|rest| rest.starts_with('/'))) {
            return Ok(FileType::Directory);
        }
        Err(io::Error::new(io::ErrorKind::NotFound, format!("missing bundled import: {}", path.display())))
    }
}
impl EvalIO for BundledIO {
    fn path_exists(&self, path: &Path) -> io::Result<bool> {
        let normalized = normalize(path)?;
        let name = normalized.to_str().ok_or_else(|| unavailable(path))?;
        Ok(FILES.iter().any(|(file, _)| *file == name || file.strip_prefix(name).is_some_and(|rest| rest.starts_with('/'))))
    }
    fn open(&self, path: &Path) -> io::Result<Box<dyn io::Read>> {
        let path = normalize(path)?;
        let text = FILES.iter().find_map(|(name, text)| (Path::new(name) == path).then_some(*text))
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound,
                format!("missing bundled import: {}", path.display())))?;
        Ok(Box::new(io::Cursor::new(text.as_bytes())))
    }
    fn file_type(&self, path: &Path) -> io::Result<FileType> { self.kind(&normalize(path)?) }
    fn read_dir(&self, path: &Path) -> io::Result<Vec<(bytes::Bytes, FileType)>> {
        let normalized = normalize(path)?;
        if !matches!(self.kind(&normalized)?, FileType::Directory) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a bundled directory"));
        }
        let directory = normalized.to_str().ok_or_else(|| unavailable(path))?;
        let mut entries = BTreeMap::new();
        for (name, _) in FILES {
            if let Some(rest) = name.strip_prefix(directory).and_then(|rest| rest.strip_prefix('/')) {
                let (first, kind) = match rest.split_once('/') {
                    Some((first, _)) => (first, FileType::Directory),
                    None => (rest, FileType::Regular),
                };
                entries.insert(first.to_owned(), kind);
            }
        }
        Ok(entries.into_iter().map(|(name, kind)| (bytes::Bytes::from(name), kind)).collect())
    }
    fn import_path(&self, path: &Path) -> io::Result<PathBuf> {
        let path = normalize(path)?;
        self.kind(&path)?;
        // This namespace contains no Nix store; this preserves bundled paths only.
        Ok(path)
    }
    fn get_env(&self, _: &OsStr) -> Option<OsString> { None }
}

fn location(error: &snix_eval::Error, severity: &'static str) -> (Diagnostic, bool) {
    let mut cause = error;
    loop {
        match &cause.kind {
            snix_eval::ErrorKind::NativeError { err, .. }
            | snix_eval::ErrorKind::BytecodeError(err) => cause = err,
            snix_eval::ErrorKind::ImportCompilerError { errors, .. } if !errors.is_empty() => cause = &errors[0],
            _ => break,
        }
    }
    let source = &cause.source;
    let mut span = cause.span;
    let parse = match &cause.kind {
        snix_eval::ErrorKind::ParseErrors(errors) => Some((source.get_file(span), errors)),
        snix_eval::ErrorKind::ImportParseError { file, errors, .. } => Some((file.clone(), errors)),
        _ => None,
    };
    let mut message = Bounded::new(MESSAGE_LIMIT);
    let _ = write!(message, "{cause}");
    if let Some((file, errors)) = parse {
        if let Some(error) = errors.first() {
            let _ = write!(message, " {error}");
            match error {
                rnix::ParseError::Unexpected(range)
                | rnix::ParseError::UnexpectedExtra(range)
                | rnix::ParseError::UnexpectedDoubleBind(range)
                | rnix::ParseError::DuplicatedArgs(range, _)
                | rnix::ParseError::UnexpectedWanted(_, range, _) => {
                    span = file.span.subspan(u32::from(range.start()) as u64, u32::from(range.end()) as u64);
                },
                rnix::ParseError::UnexpectedEOF | rnix::ParseError::UnexpectedEOFWanted(_) => {
                    span = file.span.subspan(file.span.len(), file.span.len());
                },
                _ => {},
            }
        }
    }
    let position = source.codemap().look_up_span(span);
    let truncated = message.truncated;
    (Diagnostic {
        severity, message: message.text, source: position.file.name().to_owned(),
        line: position.begin.line + 1, column: position.begin.column + 1,
        end_line: position.end.line + 1, end_column: position.end.column + 1,
    }, truncated)
}

fn evaluate(request: Request) -> Response {
    let mut response = Response { protocol: 1, id: request.id, revision: REVISION,
        ok: false, value: None, truncated: false, diagnostics: vec![], traces: vec![] };
    if request.source.len() > SOURCE_LIMIT {
        response.diagnostics.push(Diagnostic { severity: "error", message: "source exceeds the 65536-byte limit".into(),
            source: format!("{ROOT}/main.nix"), line: 1, column: 1, end_line: 1, end_column: 1 });
        return response;
    }
    let source = SourceCode::default();
    // Do not inherit upstream's placeholder builtins (including invented positions)
    // or stderr trace implementation. Every unavailable operation fails explicitly.
    let mut builtins = snix_eval::builtins::pure_builtins();
    builtins.retain(|(name, _)| *name != "trace");
    let unsupported = [
        ("trace", "message: value: abort \"trace is unsupported in the direct evaluator\""),
        ("getEnv", "name: abort \"host environment I/O is unsupported in the direct evaluator\""),
        ("readFile", "path: abort \"readFile is unsupported; only bundled import is available\""),
        ("readDir", "path: abort \"readDir is unsupported; only bundled import is available\""),
        ("pathExists", "path: abort \"pathExists is unsupported in the direct evaluator\""),
        ("fetchurl", "args: abort \"network fetching is unsupported in the direct evaluator\""),
        ("fetchTarball", "args: abort \"network fetching is unsupported in the direct evaluator\""),
        ("fetchGit", "args: abort \"network fetching is unsupported in the direct evaluator\""),
        ("derivation", "args: abort \"build execution is unsupported in the direct evaluator\""),
        ("unsafeGetAttrPos", "name: attrs: abort \"attribute position lookup is unsupported in the direct evaluator\""),
        ("addErrorContext", "context: value: abort \"addErrorContext is unsupported in the direct evaluator\""),
    ];
    let globals = snix_eval::prepare_globals(builtins, unsupported.to_vec(), source.clone(), true);
    let io: Box<dyn EvalIO> = Box::new(BundledIO);
    let result = Evaluation::builder(io).with_source_map(source.clone())
        .with_globals(globals).mode(EvalMode::Strict).build()
        // The compiler checks host Path::is_file(), not EvalIO. WASM has no
        // host file for this editor buffer, so supply its explicit directory.
        .evaluate(&request.source, Some(ROOT.into()));
    response.ok = result.errors.is_empty() && result.value.is_some();
    if let Some(value) = result.value {
        let mut output = Bounded::new(OUTPUT_LIMIT);
        let _ = write!(output, "{value}");
        response.value = Some(output.text);
        response.truncated = output.truncated;
    }
    response.truncated |= result.errors.len() + result.warnings.len() > DIAGNOSTIC_LIMIT;
    for error in result.errors.into_iter().take(DIAGNOSTIC_LIMIT) {
        let (diagnostic, truncated) = location(&error, "error");
        response.truncated |= truncated;
        response.diagnostics.push(diagnostic);
    }
    for warning in result.warnings.into_iter().take(DIAGNOSTIC_LIMIT - response.diagnostics.len()) {
        let position = source.codemap().look_up_span(warning.span);
        let mut message = Bounded::new(MESSAGE_LIMIT);
        let _ = write!(message, "{:?}", warning.kind);
        response.truncated |= message.truncated;
        response.diagnostics.push(Diagnostic { severity: "warning", message: message.text,
            source: position.file.name().to_owned(), line: position.begin.line + 1,
            column: position.begin.column + 1, end_line: position.end.line + 1,
            end_column: position.end.column + 1 });
    }
    response
}

/// JSON keeps protocol data independent of JS object conversion conventions.
#[wasm_bindgen]
pub fn evaluate_json(request: &str) -> Result<String, JsValue> {
    if request.len() > SOURCE_LIMIT * 6 + 256 { return Err(JsValue::from_str("request exceeds protocol limit")); }
    let request: Request = serde_json::from_str(request).map_err(|e| JsValue::from_str(&e.to_string()))?;
    serde_json::to_string(&evaluate(request)).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paths_cannot_escape_the_bundle() {
        assert_eq!(normalize(Path::new("/playground/v1/lib/../lib/math.nix")).unwrap(), Path::new("/playground/v1/lib/math.nix"));
        for path in ["relative.nix", "/playground/v10/file", "/playground/v1/../../etc/passwd"] {
            assert!(normalize(Path::new(path)).is_err());
        }
    }
    #[test]
    fn portable_fixtures_use_the_actual_evaluator() {
        let fixtures: serde_json::Value = serde_json::from_str(include_str!("../fixtures/v1/manifest.json")).unwrap();
        for fixture in fixtures["cases"].as_array().unwrap() {
            let response = evaluate(Request { id: 7, source: fixture["source"].as_str().unwrap().into() });
            assert!(response.ok, "{}", serde_json::to_string(&response).unwrap());
            assert_eq!(response.value.as_deref(), fixture["expected"].as_str());
        }
    }
    #[test]
    fn missing_import_and_host_io_are_errors_with_locations() {
        for text in ["import ./missing.nix", "import /etc/passwd", "builtins.getEnv \"HOME\"", "1 +", "1 / 0"] {
            let response = evaluate(Request { id: 9, source: text.into() });
            assert!(!response.ok, "{text}");
            assert!(!response.diagnostics.is_empty());
            assert!(response.diagnostics[0].line > 0);
        }
    }
    #[test]
    fn output_and_diagnostics_are_bounded() {
        let response = evaluate(Request { id: 1, source: "builtins.concatStringsSep \"\" (builtins.genList (_: \"abcdefgh\") 4096)".into() });
        assert!(response.ok);
        assert!(response.truncated);
        assert!(response.value.unwrap().len() <= OUTPUT_LIMIT);
    }
}
