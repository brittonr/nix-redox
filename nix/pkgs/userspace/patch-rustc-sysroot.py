path = "compiler/rustc_session/src/filesearch.rs"
with open(path) as f:
    content = f.read()
old = '.unwrap_or_else(|| default_from_rustc_driver_dll().expect("Failed finding sysroot"))'
new = """.unwrap_or_else(|| {
        default_from_rustc_driver_dll().unwrap_or_else(|_| {
            // Redox fallback: try current_exe() to derive sysroot
            if let Ok(exe) = std::env::current_exe() {
                if let Some(p) = exe.parent().and_then(|p| p.parent()) {
                    let rustlib = p.join("lib").join("rustlib");
                    if rustlib.exists() {
                        return p.to_path_buf();
                    }
                }
            }
            // Last resort: try well-known Redox paths
            for candidate in ["/nix/system/profile", "/usr", "/"] {
                let p = PathBuf::from(candidate);
                if p.join("lib").join("rustlib").exists() {
                    return p;
                }
            }
            PathBuf::from("/")
        })
    })"""
content = content.replace(old, new)
with open(path, 'w') as f:
    f.write(content)
print(f"  Patched {path}: Redox sysroot fallback chain")
