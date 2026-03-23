;; Minimal WASM module that exercises basic Pulley interpreter functionality.
;; Does arithmetic and returns 0 (success) via proc_exit convention.
;; No WASI imports — this is a pure compute module.
(module
  ;; Export a function that does some trivial computation
  (func $add (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add
  )

  ;; A start-like function that verifies the add function works
  (func $main (export "_start")
    ;; Compute 2 + 3, verify it equals 5
    (if (i32.ne (call $add (i32.const 2) (i32.const 3)) (i32.const 5))
      (then unreachable)
    )
    ;; If we get here, the test passed (function returns normally)
  )
)
