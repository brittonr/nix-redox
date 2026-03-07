//! Nix derivation builtins (`derivationStrict`, `placeholder`)
//!
//! Ported from upstream snix-glue `builtins/derivation.rs`, adapted for
//! synchronous, filesystem-only operation on Redox OS.
//!
//! Key differences from upstream:
//! - No fetcher support (builtin:fetchurl)
//! - No async / tokio — everything runs synchronously via snix-eval generators
//! - State is `Rc<SnixRedoxState>` instead of `Rc<SnixStoreIO>`

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use bstr::BString;
use nix_compat::derivation::{Derivation, Output};
use nix_compat::nixhash::{CAHash, HashAlgo, NixHash};
use nix_compat::store_path::{hash_placeholder, StorePath, StorePathRef};
use snix_eval::builtin_macros::builtins;
use snix_eval::generators::{self, GenCo};
use snix_eval::{
    AddContext, CoercionKind, ErrorKind, NixAttrs, NixContext, NixContextElement, NixString, Value,
    WarningKind,
};

use crate::known_paths::KnownPaths;

// ── State ──────────────────────────────────────────────────────────────────

/// Shared state for derivation builtins and (later) the EvalIO implementation.
pub struct SnixRedoxState {
    pub known_paths: RefCell<KnownPaths>,
}

// ── Constants ──────────────────────────────────────────────────────────────

const IGNORE_NULLS: &str = "__ignoreNulls";
const STRUCTURED_ATTRS_ENABLE_KEY: &str = "__structuredAttrs";
const JSON_KEY: &str = "__json";

// ── Helpers (outside the #[builtins] module) ───────────────────────────────

/// Coerce a value to a string with strong + import_paths coercion.
async fn strong_importing_coerce_to_string(
    co: &GenCo,
    val: Value,
) -> Result<NixString, ErrorKind> {
    let v = generators::request_string_coerce(
        co,
        val,
        CoercionKind {
            strong: true,
            import_paths: true,
        },
    )
    .await;

    match v {
        Ok(s) => Ok(s),
        Err(cek) => Err(ErrorKind::CatchableError(cek)),
    }
}

/// Select an optional string attribute, coercing it.
async fn select_string(
    co: &GenCo,
    attrs: &NixAttrs,
    key: &str,
) -> Result<Option<String>, ErrorKind> {
    match attrs.select(key) {
        None => Ok(None),
        Some(v) => {
            let forced = generators::request_force(co, v.clone()).await;
            if forced.is_catchable() {
                // Catchable errors in optional attr selections are
                // propagated by returning None — the caller doesn't
                // distinguish between missing and catchable here.
                return Ok(None);
            }
            let s = strong_importing_coerce_to_string(co, forced).await?;
            Ok(Some(s.as_str()?.to_owned()))
        }
    }
}

/// Populate derivation inputs from the accumulated NixContext.
fn populate_inputs(drv: &mut Derivation, full_context: NixContext, known_paths: &KnownPaths) {
    for element in full_context.iter() {
        match element {
            NixContextElement::Plain(source) => {
                let sp = StorePathRef::from_absolute_path(source.as_bytes())
                    .expect("invalid store path in context")
                    .to_owned();
                drv.input_sources.insert(sp);
            }
            NixContextElement::Single { name, derivation } => {
                let (derivation_path, _rest) =
                    StorePath::from_absolute_path_full(derivation).expect("valid store path");

                drv.input_derivations
                    .entry(derivation_path)
                    .or_default()
                    .insert(name.clone());
            }
            NixContextElement::Derivation(drv_path_str) => {
                let (drv_path, _rest) =
                    StorePath::from_absolute_path_full(drv_path_str).expect("valid store path");

                // Include all outputs of this derivation.
                let output_names = known_paths
                    .get_drv_by_drvpath(&drv_path)
                    .expect("derivation referenced in context must be known")
                    .outputs
                    .keys();

                drv.input_derivations
                    .entry(drv_path.clone())
                    .or_default()
                    .extend(output_names.cloned());

                drv.input_sources.insert(drv_path);
            }
        }
    }
}

/// Handle the fixed-output derivation parameters.
///
/// Closely follows upstream `handle_fixed_output` from
/// snix/glue/src/builtins/derivation.rs.
fn handle_fixed_output(
    drv: &mut Derivation,
    hash_str: Option<String>,
    hash_algo_str: Option<String>,
    hash_mode_str: Option<String>,
) -> Result<Option<WarningKind>, ErrorKind> {
    if let Some(hash_str) = hash_str {
        // treat an empty algo as None
        let hash_algo_str = match hash_algo_str {
            Some(s) if s.is_empty() => None,
            Some(s) => Some(s),
            None => None,
        };

        let hash_algo = hash_algo_str
            .map(|s| HashAlgo::try_from(s.as_str()))
            .transpose()
            .map_err(DerivationError::InvalidOutputHash)?;

        // Construct a NixHash — handles SRI, hex, base32, base64.
        let nixhash = NixHash::from_str(&hash_str, hash_algo)
            .map_err(DerivationError::InvalidOutputHash)?;
        let algo = nixhash.algo();

        // Set the fixed output on the "out" output.
        drv.outputs.insert(
            "out".to_string(),
            Output {
                path: None,
                ca_hash: match hash_mode_str.as_deref() {
                    None | Some("flat") => Some(CAHash::Flat(nixhash)),
                    Some("recursive") => Some(CAHash::Nar(nixhash)),
                    Some(other) => {
                        return Err(
                            DerivationError::InvalidOutputHashMode(other.to_string()).into()
                        );
                    }
                },
            },
        );

        // Warn on wrong SRI padding.
        let sri_prefix = format!("{algo}-");
        if let Some(rest) = hash_str.strip_prefix(&sri_prefix) {
            if data_encoding::BASE64.encode_len(algo.digest_length()) != rest.len() {
                return Ok(Some(WarningKind::SRIHashWrongPadding));
            }
        }
    }
    Ok(None)
}

// ── Derivation builtins module ─────────────────────────────────────────────

#[builtins(state = "Rc<SnixRedoxState>")]
pub(crate) mod derivation_builtins {
    use super::*;
    use genawaiter::rc::Gen;

    #[builtin("placeholder")]
    async fn builtin_placeholder(co: GenCo, input: Value) -> Result<Value, ErrorKind> {
        if input.is_catchable() {
            return Ok(input);
        }
        let s = input.to_str().context("builtins.placeholder")?;
        let output_name = s.as_str()?;

        nix_compat::derivation::validate_output_name(output_name).map_err(|e| {
            ErrorKind::Abort(format!("invalid output name in builtins.placeholder: {e}"))
        })?;

        Ok(hash_placeholder(output_name).into())
    }

    /// `builtins.derivationStrict` — the core of Nix package building.
    #[builtin("derivationStrict")]
    async fn builtin_derivation_strict(
        state: Rc<SnixRedoxState>,
        co: GenCo,
        input: Value,
    ) -> Result<Value, ErrorKind> {
        if input.is_catchable() {
            return Ok(input);
        }

        let input = input.to_attrs()?;
        let name = generators::request_force(&co, input.select_required("name")?.clone()).await;
        if name.is_catchable() {
            return Ok(name);
        }
        let name = name.to_str().context("determining derivation name")?;
        if name.is_empty() {
            return Err(ErrorKind::Abort("derivation has empty name".to_string()));
        }
        let name = name.as_str()?;

        let mut drv = Derivation::default();
        drv.outputs.insert("out".to_string(), Default::default());
        let mut input_context = NixContext::new();

        // Check __ignoreNulls
        let ignore_nulls = match input.select(IGNORE_NULLS) {
            Some(b) => generators::request_force(&co, b.clone()).await.as_bool()?,
            None => false,
        };

        // Check __structuredAttrs
        let mut structured_attrs: Option<BTreeMap<String, serde_json::Value>> =
            match input.select(STRUCTURED_ATTRS_ENABLE_KEY) {
                Some(b) => generators::request_force(&co, b.clone())
                    .await
                    .as_bool()?
                    .then_some(Default::default()),
                None => None,
            };

        // Iterate over all input attributes in sorted order.
        for (arg_name, arg_value) in input.clone().into_iter_sorted() {
            let arg_name = arg_name.as_str()?;

            let value = generators::request_force(&co, arg_value).await;
            if value.is_catchable() {
                return Ok(value);
            }

            // Skip nulls if __ignoreNulls is set
            if ignore_nulls && matches!(value, Value::Null) {
                continue;
            }

            match arg_name {
                // ── args ────────────────────────────────────────────
                "args" => {
                    for arg in value.to_list()? {
                        let s = strong_importing_coerce_to_string(&co, arg).await?;
                        if let Some(ctx) = s.iter_context().next() {
                            input_context.extend(ctx.iter().cloned());
                        }
                        drv.arguments.push(s.as_str()?.to_owned());
                    }
                }

                // ── outputs ─────────────────────────────────────────
                "outputs" => {
                    let outputs = value
                        .to_list()
                        .context("looking at the `outputs` parameter of the derivation")?;

                    drv.outputs.clear();
                    let mut output_names = Vec::with_capacity(outputs.len());

                    for output in outputs {
                        let output_name = generators::request_force(&co, output)
                            .await
                            .to_str()
                            .context("determining output name")?;

                        if let Some(ctx) = output_name.iter_context().next() {
                            input_context.extend(ctx.iter().cloned());
                        }

                        let out_str = output_name.as_str()?.to_owned();
                        if drv
                            .outputs
                            .insert(out_str.clone(), Default::default())
                            .is_some()
                        {
                            return Err(
                                DerivationError::DuplicateOutput(out_str.clone()).into()
                            );
                        }
                        output_names.push(out_str);
                    }

                    match structured_attrs.as_mut() {
                        Some(sa) => {
                            sa.insert(arg_name.into(), output_names.clone().into());
                        }
                        None => {
                            drv.environment.insert(
                                arg_name.into(),
                                BString::from(output_names.join(" ")),
                            );
                        }
                    }
                }

                // ── builder / system ─────────────────────────────────
                "builder" | "system" => {
                    let val_str = strong_importing_coerce_to_string(&co, value).await?;
                    if let Some(ctx) = val_str.iter_context().next() {
                        input_context.extend(ctx.iter().cloned());
                    }

                    if arg_name == "builder" {
                        val_str.as_str()?.clone_into(&mut drv.builder);
                    } else {
                        val_str.as_str()?.clone_into(&mut drv.system);
                    }

                    if let Some(ref mut sa) = structured_attrs {
                        sa.insert(arg_name.to_owned(), val_str.as_str()?.to_owned().into());
                    } else {
                        drv.environment
                            .insert(arg_name.into(), val_str.as_bytes().into());
                    }
                }

                // ── skip special keys ────────────────────────────────
                STRUCTURED_ATTRS_ENABLE_KEY if structured_attrs.is_some() => continue,
                IGNORE_NULLS => continue,

                // ── all other attributes ─────────────────────────────
                _ => {
                    match structured_attrs {
                        Some(ref mut sa) => {
                            // Structured attrs: convert to JSON
                            let val = generators::request_force(&co, value).await;
                            if val.is_catchable() {
                                return Ok(val);
                            }
                            let (val_json, context) = val.into_contextful_json(&co).await?;
                            input_context.extend(context.into_iter());
                            sa.insert(arg_name.to_owned(), val_json);
                        }
                        None => {
                            // Non-SA: coerce to string for env
                            if arg_name == JSON_KEY {
                                return Err(
                                    DerivationError::StructuredAttrsJsonKeyPresent.into()
                                );
                            }
                            let val_str =
                                strong_importing_coerce_to_string(&co, value).await?;
                            if let Some(ctx) = val_str.iter_context().next() {
                                input_context.extend(ctx.iter().cloned());
                            }
                            drv.environment
                                .insert(arg_name.into(), val_str.as_bytes().into());
                        }
                    }
                }
            }
        }
        // ── end of per-attribute loop ──────────────────────────────────

        // Handle fixed-output derivation configuration.
        {
            let output_hash = select_string(&co, &input, "outputHash")
                .await
                .context("evaluating `outputHash`")?;
            let output_hash_algo = select_string(&co, &input, "outputHashAlgo")
                .await
                .context("evaluating `outputHashAlgo`")?;
            let output_hash_mode = select_string(&co, &input, "outputHashMode")
                .await
                .context("evaluating `outputHashMode`")?;

            if let Some(warning) =
                handle_fixed_output(&mut drv, output_hash, output_hash_algo, output_hash_mode)?
            {
                generators::emit_warning_kind(&co, warning).await;
            }
        }

        // Each output name needs an empty string in the environment for
        // ATerm serialisation (used by output path calculation).
        for output in drv.outputs.keys() {
            if drv
                .environment
                .insert(output.to_string(), String::new().into())
                .is_some()
            {
                generators::emit_warning_kind(
                    &co,
                    WarningKind::ShadowedOutput(output.to_string()),
                )
                .await;
            }
        }

        // If structured attrs, insert __json into environment.
        if let Some(sa) = structured_attrs {
            drv.environment.insert(
                JSON_KEY.to_string(),
                BString::from(serde_json::to_string(&sa).map_err(|e| {
                    ErrorKind::Abort(format!("structured attrs serialisation: {e}"))
                })?),
            );
        }

        // Populate inputs from context.
        let mut known_paths = state.as_ref().known_paths.borrow_mut();
        populate_inputs(&mut drv, input_context, &known_paths);

        // Validate.
        drv.validate(false)
            .map_err(DerivationError::InvalidDerivation)?;

        // Calculate output paths.
        debug_assert!(
            drv.outputs.values().all(|o| o.path.is_none()),
            "outputs should still be unset"
        );

        let hash_derivation_modulo = drv.hash_derivation_modulo(|drv_path| {
            *known_paths
                .get_hash_derivation_modulo(&drv_path.to_owned())
                .unwrap_or_else(|| panic!("{drv_path} not found"))
        });

        drv.calculate_output_paths(name, &hash_derivation_modulo)
            .map_err(DerivationError::InvalidDerivation)?;

        let drv_path = drv
            .calculate_derivation_path(name)
            .map_err(DerivationError::InvalidDerivation)?;

        // Build the return attrset: { drvPath = "..."; out = "..."; ... }
        let result = Value::attrs(NixAttrs::from_iter(
            drv.outputs
                .iter()
                .map(|(out_name, output)| {
                    (
                        out_name.clone(),
                        Value::from(NixString::new_context_from(
                            NixContextElement::Single {
                                name: out_name.clone(),
                                derivation: drv_path.to_absolute_path(),
                            }
                            .into(),
                            output.path.as_ref().unwrap().to_absolute_path(),
                        )),
                    )
                })
                .chain(std::iter::once((
                    "drvPath".to_owned(),
                    Value::from(NixString::new_context_from(
                        NixContextElement::Derivation(drv_path.to_absolute_path()).into(),
                        drv_path.to_absolute_path(),
                    )),
                ))),
        ));

        // Register in known_paths.
        known_paths.add_derivation(drv_path, drv);

        Ok(result)
    }
}

// ── Error type ─────────────────────────────────────────────────────────────

#[derive(Debug)]
pub enum DerivationError {
    InvalidDerivation(nix_compat::derivation::DerivationError),
    InvalidOutputHash(nix_compat::nixhash::Error),
    InvalidOutputHashMode(String),
    DuplicateOutput(String),
    #[allow(dead_code)]
    DuplicateEnvVar(String),
    StructuredAttrsJsonKeyPresent,
}

impl std::fmt::Display for DerivationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidDerivation(e) => write!(f, "invalid derivation: {e}"),
            Self::InvalidOutputHash(e) => write!(f, "invalid output hash: {e}"),
            Self::InvalidOutputHashMode(m) => write!(f, "invalid outputHashMode: {m}"),
            Self::DuplicateOutput(n) => write!(f, "duplicate output: {n}"),
            Self::DuplicateEnvVar(k) => write!(f, "duplicate env var: {k}"),
            Self::StructuredAttrsJsonKeyPresent => {
                write!(f, "__json key not allowed without __structuredAttrs = true")
            }
        }
    }
}

impl std::error::Error for DerivationError {}

impl From<DerivationError> for ErrorKind {
    fn from(e: DerivationError) -> ErrorKind {
        ErrorKind::Abort(e.to_string())
    }
}
