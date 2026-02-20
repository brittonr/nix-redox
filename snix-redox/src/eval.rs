//! Nix expression evaluation using snix-eval's bytecode VM.

use std::io::{self, BufRead, Write};

use snix_eval::Evaluation;

/// Evaluate a Nix expression from --expr or --file
pub fn run(expr: Option<String>, file: Option<String>) -> Result<(), Box<dyn std::error::Error>> {
    let source = match (expr, file) {
        (Some(e), _) => e,
        (_, Some(f)) => std::fs::read_to_string(&f)?,
        _ => return Err("provide --expr or --file".into()),
    };

    let result = evaluate(&source)?;
    println!("{result}");
    Ok(())
}

/// Show a .drv file in human-readable JSON
pub fn show_derivation(path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let bytes = std::fs::read(path)?;

    // Trim trailing whitespace (Nix derivations shouldn't have it)
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
    let eval = Evaluation::builder_impure().build();
    let result = eval.evaluate(expr, None);

    if !result.errors.is_empty() {
        let errors: Vec<String> = result.errors.iter().map(|e| format!("{e}")).collect();
        return Err(errors.join("\n").into());
    }

    match result.value {
        Some(v) => Ok(format!("{v}")),
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
        // List representation may vary, just check it contains the elements
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
        // attrNames returns a sorted list
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
        let result = run(None, None);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("provide --expr or --file"));
    }

    // ===== Derivation Parsing =====

    #[test]
    fn test_derivation_parsing() {
        let drv_path = format!(
            "{}/testdata/4wvvbi4jwn0prsdxb7vs673qa5h9gr7x-foo.drv",
            env!("CARGO_MANIFEST_DIR")
        );

        let bytes = std::fs::read(&drv_path).expect("failed to read test derivation file");
        // Trim trailing whitespace — pre-commit hooks may add a trailing newline
        let trimmed = bytes.strip_suffix(b"\n").unwrap_or(&bytes);

        let drv = nix_compat::derivation::Derivation::from_aterm_bytes(trimmed);
        assert!(drv.is_ok(), "failed to parse derivation: {:?}", drv.err());

        let drv = drv.unwrap();
        // Basic sanity checks on the parsed derivation
        assert!(!drv.outputs.is_empty(), "derivation should have outputs");
    }
}
