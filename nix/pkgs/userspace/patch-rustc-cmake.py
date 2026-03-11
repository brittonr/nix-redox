path = "src/bootstrap/src/core/build_steps/llvm.rs"
with open(path) as f:
    content = f.read()
# Add Redox handling before the "none" catch-all
content = content.replace(
    '} else if target.contains("none") {',
    '} else if target.contains("redox") {\n            cfg.define("CMAKE_SYSTEM_NAME", "UnixPaths");\n        } else if target.contains("none") {'
)
with open(path, 'w') as f:
    f.write(content)
print(f"  Patched {path}")
