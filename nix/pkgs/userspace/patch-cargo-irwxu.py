path = "src/tools/cargo/crates/cargo-util/src/paths.rs"
with open(path) as f:
    content = f.read()
content = content.replace(
    'u32::from(libc::S_IRWXU | libc::S_IRWXG | libc::S_IRWXO)',
    '(libc::S_IRWXU | libc::S_IRWXG | libc::S_IRWXO) as u32'
)
with open(path, 'w') as f:
    f.write(content)
print(f"  Patched {path}")
