//! Nix expression evaluation using upstream snix-eval + snix-glue.
//!
//! Sets up a tokio runtime, constructs in-memory store services, and
//! uses upstream SnixStoreIO with derivation/fetcher/import builtins.

use std::io::{self, BufRead, Write};
use std::rc::Rc;
use std::sync::Arc;

use snix_eval::{EvalIO, Evaluation};

use snix_build::buildservice::DummyBuildService;
use snix_glue::builtins::{add_derivation_builtins, add_fetcher_builtins, add_import_builtins};
use snix_glue::snix_store_io::SnixStoreIO;
use snix_store::utils::{construct_services, ServiceUrlsMemory};

/// Evaluate a Nix expression from --expr or --file
pub fn run(
    expr: Option<String>,
    file: Option<String>,
    raw: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let source = match (expr, file) {
        (Some(e), _) => e,
        (_, Some(f)) => std::fs::read_to_string(&f)?,
        _ => return Err("provide --expr or --file".into()),
    };

    let result = evaluate(&source)?;
    if raw {
        let s = result.to_string();
        if s.starts_with('"') && s.ends_with('"') && s.len() >= 2 {
            let inner = &s[1..s.len() - 1];
            let unescaped = inner
                .replace("\\\"", "\"")
                .replace("\\\\", "\\")
                .replace("\\n", "\n")
                .replace("\\t", "\t");
            print!("{unescaped}");
        } else {
            print!("{s}");
        }
    } else {
        println!("{result}");
    }
    Ok(())
}

/// Show a .drv file in human-readable JSON
pub fn show_derivation(path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let bytes = std::fs::read(path)?;
    let trimmed = bytes.as_slice();

    match nix_compat::derivation::Derivation::from_aterm_bytes(trimmed) {
        Ok(drv) => {
            let json = serde_json::json!({
                "args": drv.arguments,
                "builder": drv.builder,
                "env": drv.environment.into_iter()
                    .map(|(k, v)| (k, v.to_string()))
                    .collect::<std::collections::BTreeMap<String, String>>(),
                "inputDrvs": drv.input_derivations,
                "inputSrcs": drv.input_sources,
                "outputs": drv.outputs,
                "system": drv.system,
            });
            println!("{}", serde_json::to_string_pretty(&json)?);
        }
        Err(e) => return Err(format!("parse error: {e:#?}").into()),
    }

    Ok(())
}

/// Interactive REPL
pub fn repl() -> Result<(), Box<dyn std::error::Error>> {
    println!("snix repl (Redox OS)");
    println!("Type Nix expressions. Ctrl-D to exit.\n");

    let stdin = io::stdin();
    let mut stdout = io::stdout();

    for line in stdin.lock().lines() {
        let line = line?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        match evaluate(line) {
            Ok(val) => println!("{val}"),
            Err(e) => eprintln!("error: {e}"),
        }

        print!("nix> ");
        stdout.flush()?;
    }

    Ok(())
}

/// Core evaluation function
fn evaluate(expr: &str) -> Result<String, Box<dyn std::error::Error>> {
    let (result, _io) = evaluate_with_state(expr)?;
    Ok(result)
}

/// Evaluate a Nix expression, returning both the string result and the
/// shared SnixStoreIO (which contains KnownPaths with all registered
/// derivations).
///
/// Uses upstream SnixStoreIO with in-memory store services for
/// derivation path calculation, fetcher builtins, and import builtins.
/// A tokio runtime is created for the async store operations.
pub fn evaluate_with_state(
    expr: &str,
) -> Result<(String, Rc<SnixStoreIO>), Box<dyn std::error::Error>> {
    // Install ring as the default rustls crypto provider. Required because
    // we use reqwest with rustls-no-provider (to avoid aws-lc-rs which
    // doesn't compile on Redox). This is idempotent — repeated calls are fine.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let runtime = tokio::runtime::Runtime::new()
        .map_err(|e| format!("tokio runtime: {e}"))?;

    let (blob_service, directory_service, path_info_service, nar_calculation_service) =
        runtime.block_on(async {
            construct_services(
                <ServiceUrlsMemory as clap::Parser>::parse_from(std::iter::empty::<&str>()),
            )
            .await
        })
        .map_err(|e| format!("store services: {e}"))?;

    let io = Rc::new(SnixStoreIO::new(
        blob_service,
        directory_service,
        path_info_service,
        nar_calculation_service.into(),
        Arc::<DummyBuildService>::default(),
        runtime.handle().clone(),
        Vec::new(),
    ));

    let mut eval_builder =
        Evaluation::builder(io.clone() as Rc<dyn EvalIO>).enable_import();
    eval_builder = add_derivation_builtins(eval_builder, Rc::clone(&io));
    eval_builder = add_fetcher_builtins(eval_builder, Rc::clone(&io));
    eval_builder = add_import_builtins(eval_builder, Rc::clone(&io));
    let eval = eval_builder.build();

    let result = eval.evaluate(expr, None);

    // Keep runtime alive until evaluation completes — SnixStoreIO holds
    // a handle but the runtime itself must outlive it.
    let _rt_guard = runtime;

    if !result.errors.is_empty() {
        let errors: Vec<String> = result.errors.iter().map(|e| format!("{e}")).collect();
        return Err(errors.join("\n").into());
    }

    match result.value {
        Some(v) => Ok((format!("{v}"), io)),
        None => Err("no value produced".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ===== Arithmetic =====

    #[test]
    fn test_arithmetic_addition() {
        let result = evaluate("1 + 1").unwrap();
        assert_eq!(result, "2");
    }

    #[test]
    fn test_arithmetic_subtraction() {
        let result = evaluate("10 - 3").unwrap();
        assert_eq!(result, "7");
    }

    #[test]
    fn test_arithmetic_multiplication() {
        let result = evaluate("6 * 7").unwrap();
        assert_eq!(result, "42");
    }

    #[test]
    fn test_arithmetic_division() {
        let result = evaluate("10 / 3").unwrap();
        assert_eq!(result, "3");
    }

    // ===== Strings =====

    #[test]
    fn test_string_literal() {
        let result = evaluate("\"hello\"").unwrap();
        assert_eq!(result, "\"hello\"");
    }

    #[test]
    fn test_string_concatenation() {
        let result = evaluate("\"hello\" + \" world\"").unwrap();
        assert_eq!(result, "\"hello world\"");
    }

    // ===== Booleans =====

    #[test]
    fn test_boolean_true() {
        let result = evaluate("true").unwrap();
        assert_eq!(result, "true");
    }

    #[test]
    fn test_boolean_false() {
        let result = evaluate("false").unwrap();
        assert_eq!(result, "false");
    }

    #[test]
    fn test_boolean_negation() {
        let result = evaluate("!true").unwrap();
        assert_eq!(result, "false");
    }

    #[test]
    fn test_boolean_and() {
        let result = evaluate("true && false").unwrap();
        assert_eq!(result, "false");
    }

    #[test]
    fn test_boolean_or() {
        let result = evaluate("true || false").unwrap();
        assert_eq!(result, "true");
    }

    // ===== Lists =====

    #[test]
    fn test_list_simple() {
        let result = evaluate("[1 2 3]").unwrap();
        assert!(result.contains("1"));
        assert!(result.contains("2"));
        assert!(result.contains("3"));
    }

    // ===== Attribute Sets =====

    #[test]
    fn test_attrset_access() {
        let result = evaluate("{ a = 1; }.a").unwrap();
        assert_eq!(result, "1");
    }

    #[test]
    fn test_attrset_nested_access() {
        let result = evaluate("{ a = { b = 2; }; }.a.b").unwrap();
        assert_eq!(result, "2");
    }

    // ===== Let Expressions =====

    #[test]
    fn test_let_expression() {
        let result = evaluate("let x = 5; in x * 2").unwrap();
        assert_eq!(result, "10");
    }

    // ===== Builtins =====

    #[test]
    fn test_builtin_length() {
        let result = evaluate("builtins.length [1 2 3]").unwrap();
        assert_eq!(result, "3");
    }

    #[test]
    fn test_builtin_head() {
        let result = evaluate("builtins.head [42 99]").unwrap();
        assert_eq!(result, "42");
    }

    #[test]
    fn test_builtin_typeof() {
        let result = evaluate("builtins.typeOf 1").unwrap();
        assert_eq!(result, "\"int\"");
    }

    #[test]
    fn test_builtin_attrnames() {
        let result = evaluate("builtins.attrNames { b = 1; a = 2; }").unwrap();
        assert!(result.contains("a"));
        assert!(result.contains("b"));
    }

    // ===== Functions =====

    #[test]
    fn test_function_simple() {
        let result = evaluate("(x: x + 1) 5").unwrap();
        assert_eq!(result, "6");
    }

    #[test]
    fn test_function_pattern_matching() {
        let result = evaluate("let f = {a, b}: a + b; in f { a = 3; b = 4; }").unwrap();
        assert_eq!(result, "7");
    }

    // ===== Conditionals =====

    #[test]
    fn test_conditional_true_branch() {
        let result = evaluate("if true then 1 else 2").unwrap();
        assert_eq!(result, "1");
    }

    #[test]
    fn test_conditional_false_branch() {
        let result = evaluate("if false then 1 else 2").unwrap();
        assert_eq!(result, "2");
    }

    // ===== String Interpolation =====

    #[test]
    fn test_string_interpolation() {
        let result = evaluate("let name = \"world\"; in \"hello ${name}\"").unwrap();
        assert_eq!(result, "\"hello world\"");
    }

    // ===== Error Cases =====

    #[test]
    fn test_invalid_syntax_error() {
        let result = evaluate("1 +");
        assert!(result.is_err());
    }

    #[test]
    fn test_run_no_args_error() {
        let result = run(None, None, false);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("provide --expr or --file"));
    }

    // ===== Derivation Parsing =====

    #[test]
    fn test_derivation_parsing() {
        let bytes: &[u8] = include_bytes!("../testdata/4wvvbi4jwn0prsdxb7vs673qa5h9gr7x-foo.drv");
        let trimmed = bytes.strip_suffix(b"\n").unwrap_or(bytes);

        let drv = nix_compat::derivation::Derivation::from_aterm_bytes(trimmed);
        assert!(drv.is_ok(), "failed to parse derivation: {:?}", drv.err());

        let drv = drv.unwrap();
        assert!(!drv.outputs.is_empty(), "derivation should have outputs");
    }

    // ===== Derivation Builtins (upstream) =====

    #[test]
    fn test_derivation_outpath() {
        let result = evaluate(
            r#"(derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; }).outPath"#,
        ).unwrap();
        assert_eq!(result, r#""/nix/store/xpcvxsx5sw4rbq666blz6sxqlmsqphmr-foo""#);
    }

    #[test]
    fn test_derivation_drvpath() {
        let result = evaluate(
            r#"(derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; }).drvPath"#,
        ).unwrap();
        assert!(result.contains("/nix/store/"), "should be a store path");
        assert!(result.contains("-foo.drv"), "should be a .drv");
    }

    #[test]
    fn test_derivation_empty_name_fails() {
        let result = evaluate(
            r#"(derivation { name = ""; builder = "/bin/sh"; system = "x86_64-linux"; }).outPath"#,
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_fod_recursive_sha256() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHashMode = "recursive"; outputHashAlgo = "sha256"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(result, r#""/nix/store/17wgs52s7kcamcyin4ja58njkf91ipq8-foo""#);
    }

    #[test]
    fn test_fod_recursive_sha256_other_name() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo2"; builder = "/bin/sh"; system = "x86_64-linux"; outputHashMode = "recursive"; outputHashAlgo = "sha256"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(result, r#""/nix/store/gi0p8vd635vpk1nq029cz3aa3jkhar5k-foo2""#);
    }

    #[test]
    fn test_fod_flat_sha256() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHashMode = "flat"; outputHashAlgo = "sha256"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(result, r#""/nix/store/q4pkwkxdib797fhk22p0k3g1q32jmxvf-foo""#);
    }

    #[test]
    fn test_fod_sha256_algo_omitted() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHashMode = "recursive"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(result, r#""/nix/store/17wgs52s7kcamcyin4ja58njkf91ipq8-foo""#);
    }

    #[test]
    fn test_fod_sha256_mode_omitted() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath"#,
        ).unwrap();
        assert_eq!(result, r#""/nix/store/q4pkwkxdib797fhk22p0k3g1q32jmxvf-foo""#);
    }

    #[test]
    fn test_derivation_no_outputhash() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; }).outPath"#,
        ).unwrap();
        assert_eq!(result, r#""/nix/store/xpcvxsx5sw4rbq666blz6sxqlmsqphmr-foo""#);
    }

    #[test]
    fn test_derivation_multiple_outputs() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; outputs = ["foo" "bar"]; system = "x86_64-linux"; }).outPath"#,
        ).unwrap();
        assert_eq!(result, r#""/nix/store/hkwdinvz2jpzgnjy9lv34d2zxvclj4s3-foo-foo""#);
    }

    #[test]
    fn test_derivation_with_args() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; args = ["--foo" "42" "--bar"]; system = "x86_64-linux"; }).outPath"#,
        ).unwrap();
        assert_eq!(result, r#""/nix/store/365gi78n2z7vwc1bvgb98k0a9cqfp6as-foo""#);
    }

    #[test]
    fn test_derivation_with_dep() {
        let result = evaluate(r#"
            let
              bar = builtins.derivation {
                name = "bar";
                builder = ":";
                system = ":";
                outputHash = "08813cbee9903c62be4c5027726a418a300da4500b2d369d3af9286f4815ceba";
                outputHashAlgo = "sha256";
                outputHashMode = "recursive";
              };
            in
            (builtins.derivation {
              name = "foo";
              builder = ":";
              system = ":";
              inherit bar;
            }).outPath
        "#).unwrap();
        assert_eq!(result, r#""/nix/store/5vyvcwah9l9kf07d52rcgdk70g2f4y13-foo""#);
    }

    #[test]
    fn test_fod_same_hash_same_outpath() {
        let result = evaluate(r#"
            (builtins.derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath ==
            (builtins.derivation { name = "foo"; builder = "/bin/aa"; system = "x86_64-linux"; outputHash = "sha256-Q3QXOoy+iN4VK2CflvRulYvPZXYgF0dO7FoF7CvWFTA="; }).outPath
        "#).unwrap();
        assert_eq!(result, "true");
    }

    #[test]
    fn test_ignore_nulls_true() {
        let without = evaluate(
            r#"(builtins.derivation { name = "foo"; system = ":"; builder = ":"; __ignoreNulls = true; }).drvPath"#,
        ).unwrap();
        let with_null = evaluate(
            r#"(builtins.derivation { name = "foo"; system = ":"; builder = ":"; __ignoreNulls = true; ignoreme = null; }).drvPath"#,
        ).unwrap();
        assert_eq!(without, with_null);
    }

    #[test]
    fn test_placeholder() {
        let result = evaluate(r#"builtins.placeholder "out""#).unwrap();
        assert_eq!(
            result,
            r#""/1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9""#
        );
    }

    #[test]
    fn test_derivation_type_attr() {
        let result = evaluate(
            r#"(derivation { name = "foo"; builder = "/bin/sh"; system = "x86_64-linux"; }).type"#,
        ).unwrap();
        assert_eq!(result, r#""derivation""#);
    }

    #[test]
    fn test_derivation_duplicate_outputs_fails() {
        let result = evaluate(
            r#"(builtins.derivation { name = "foo"; builder = "/bin/sh"; outputs = ["foo" "foo"]; system = "x86_64-linux"; }).outPath"#,
        );
        assert!(result.is_err());
    }
}
