path = "compiler/rustc_target/src/spec/base/redox.rs"
with open(path) as f:
    content = f.read()
if "generate_arange_section" not in content:
    # Insert before the closing of the TargetOptions block
    # The file returns TargetOptions { ... }
    content = content.replace(
        "..Default::default()",
        "generate_arange_section: false,\n        ..Default::default()"
    )
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path}: disabled generate_arange_section")
else:
    print(f"  {path}: already patched")
