#!/usr/bin/env python3
"""
Patch ld_so to search .symtab for LOCAL __relibc_init_* symbols.

Problem: Pre-built shared libraries (like librustc_driver.so) have relibc
statically linked with __relibc_init_proc_fd etc. as LOCAL symbols (due to
Rust's `local: *;` version script). ld_so's get_sym() only searches .dynsym
(via hash table), so it can't find these symbols to inject proc_fd/ns_fd.

Fix: During DSO construction (when the full ELF file data is available),
scan .symtab section headers to find LOCAL __relibc_init_* symbols and
store their runtime addresses. In run_init, fall back to these addresses
when get_sym fails.
"""

import sys
import os

def patch_dso_rs(path):
    with open(path) as f:
        content = f.read()

    # 1. Add the LocalInitSyms struct and field to DSO

    # Find the DSO struct definition and add the field
    old_struct = '''pub struct DSO {
    pub name: String,
    pub id: usize,
    pub dlopened: bool,
    pub entry_point: usize,
    /// Loaded library in-memory data
    pub mmap: &'static [u8],
    pub tls_module_id: usize,
    pub tls_offset: usize,

    pub(super) dynamic: Dynamic<'static>,

    pub scope: spin::Once<Scope>,
    /// Position Independent Executable.
    pub pie: bool,

    /// Whether this DSO *and* its dependencies have been successfully loaded.
    is_ready: AtomicBool,
}'''

    new_struct = '''/// Addresses of LOCAL __relibc_init_* symbols found via .symtab scanning.
/// Used as fallback when .dynsym lookup fails (symbols hidden by version script).
#[derive(Default)]
pub(super) struct LocalInitSyms {
    pub environ: Option<usize>,
    pub proc_fd: Option<usize>,
    pub ns_fd: Option<usize>,
    pub cwd_ptr: Option<usize>,
    pub cwd_len: Option<usize>,
    pub cwd_fd: Option<usize>,
}

pub struct DSO {
    pub name: String,
    pub id: usize,
    pub dlopened: bool,
    pub entry_point: usize,
    /// Loaded library in-memory data
    pub mmap: &'static [u8],
    pub tls_module_id: usize,
    pub tls_offset: usize,

    pub(super) dynamic: Dynamic<'static>,

    pub scope: spin::Once<Scope>,
    /// Position Independent Executable.
    pub pie: bool,

    /// Whether this DSO *and* its dependencies have been successfully loaded.
    is_ready: AtomicBool,

    /// LOCAL __relibc_init_* symbol addresses from .symtab (fallback for version-script-hidden symbols)
    pub(super) local_init_syms: LocalInitSyms,
}'''

    if old_struct not in content:
        print(f"WARNING: DSO struct not found in {path}, skipping", file=sys.stderr)
        return False

    content = content.replace(old_struct, new_struct)

    # 2. Add local_init_syms field initialization in DSO::new
    old_new = '''            pie: is_pie_enabled(&elf),
            dynamic,
            scope: spin::Once::new(),
            is_ready: AtomicBool::new(false),
        };

        Ok((dso, tcb_master, elf.elf_program_headers().to_vec()))'''

    new_new = '''            pie: is_pie_enabled(&elf),
            dynamic,
            scope: spin::Once::new(),
            is_ready: AtomicBool::new(false),
            local_init_syms: Self::scan_symtab_for_init_syms(data, mmap.as_ptr() as usize, is_pie_enabled(&elf)),
        };

        Ok((dso, tcb_master, elf.elf_program_headers().to_vec()))'''

    if old_new not in content:
        print(f"WARNING: DSO::new constructor body not found in {path}, skipping", file=sys.stderr)
        return False

    content = content.replace(old_new, new_new)

    # 3. Add the scan_symtab_for_init_syms method to DSO impl
    # Find a good insertion point - right before get_sym
    old_get_sym = '''    pub fn get_sym<'a>(&self, name: &'a str) -> Option<(Symbol<'a>, SymbolBinding)> {'''

    new_get_sym = '''    /// Scan .symtab section for LOCAL __relibc_init_* symbols.
    /// Called during DSO construction when the full ELF file data is available.
    /// Returns runtime addresses of found symbols.
    fn scan_symtab_for_init_syms(data: &[u8], load_base: usize, pie: bool) -> LocalInitSyms {
        use object::read::elf::FileHeader as _;
        use object::read::elf::SectionHeader as SH;
        let mut result = LocalInitSyms::default();

        let file_header = match shim::FileHeader::parse(data) {
            Ok(hdr) => hdr,
            Err(_) => return result,
        };
        let endian = NativeEndian;
        let sections = match file_header.sections(endian, data) {
            Ok(s) => s,
            Err(_) => return result,
        };

        // Find SHT_SYMTAB section (NOT SHT_DYNSYM) by iterating section headers
        let mut symtab_idx = None;
        for (i, section) in sections.iter().enumerate() {
            if section.sh_type(endian) == elf::SHT_SYMTAB {
                symtab_idx = Some(object::SectionIndex(i));
                break;
            }
        }
        let symtab_idx = match symtab_idx {
            Some(idx) => idx,
            None => return result,
        };
        let symbols = match sections.symbol_table_by_index(endian, data, symtab_idx) {
            Ok(st) => st,
            Err(_) => return result,
        };
        let strtab_link = sections.iter().nth(symtab_idx.0)
            .map(|s| s.sh_link(endian) as usize);
        let strings = match strtab_link {
            Some(link) => match sections.strings(endian, data, object::SectionIndex(link)) {
                Ok(s) => s,
                Err(_) => return result,
            },
            None => return result,
        };

        let base = if pie { load_base } else { 0 };

        for sym in symbols.symbols() {
            if sym.st_shndx(endian) == elf::SHN_UNDEF || sym.st_size(endian) == 0 {
                continue;
            }
            if sym.st_type() != elf::STT_OBJECT {
                continue;
            }
            let name = match sym.name(endian, strings) {
                Ok(n) => n,
                Err(_) => continue,
            };
            let addr = base + sym.st_value(endian) as usize;
            match name {
                b"__relibc_init_environ" => result.environ = Some(addr),
                b"__relibc_init_proc_fd" => result.proc_fd = Some(addr),
                b"__relibc_init_ns_fd" => result.ns_fd = Some(addr),
                b"__relibc_init_cwd_ptr" => result.cwd_ptr = Some(addr),
                b"__relibc_init_cwd_len" => result.cwd_len = Some(addr),
                b"__relibc_init_cwd_fd" => result.cwd_fd = Some(addr),
                _ => {}
            }
        }
        result
    }

    pub fn get_sym<'a>(&self, name: &'a str) -> Option<(Symbol<'a>, SymbolBinding)> {'''

    if old_get_sym not in content:
        print(f"WARNING: get_sym method not found in {path}, skipping", file=sys.stderr)
        return False

    content = content.replace(old_get_sym, new_get_sym)

    with open(path, 'w') as f:
        f.write(content)
    return True


def patch_linker_rs(path):
    with open(path) as f:
        content = f.read()

    # Modify run_init to use local_init_syms as fallback for proc_fd and ns_fd injection
    # The existing code does:
    #   if let Some((symbol, _)) = obj.get_sym("__relibc_init_proc_fd") { ... }
    # We add: else if let Some(addr) = obj.local_init_syms.proc_fd { ... }

    old_proc_fd = '''            if let Some((symbol, _)) = obj.get_sym("__relibc_init_proc_fd") {
                let proc_fd = redox_rt::current_proc_fd().as_raw_fd();
                unsafe {
                    symbol.as_ptr().cast::<usize>().write(proc_fd);
                }
            }'''

    new_proc_fd = '''            if let Some((symbol, _)) = obj.get_sym("__relibc_init_proc_fd") {
                let proc_fd = redox_rt::current_proc_fd().as_raw_fd();
                unsafe {
                    symbol.as_ptr().cast::<usize>().write(proc_fd);
                }
            } else if let Some(addr) = obj.local_init_syms.proc_fd {
                // Fallback: symbol is LOCAL (hidden by version script), found via .symtab
                let proc_fd = redox_rt::current_proc_fd().as_raw_fd();
                unsafe {
                    (addr as *mut usize).write(proc_fd);
                }
            }'''

    if old_proc_fd not in content:
        print(f"WARNING: proc_fd injection block not found in {path}, skipping", file=sys.stderr)
        return False

    content = content.replace(old_proc_fd, new_proc_fd)

    # Same for ns_fd — match both possible signatures
    # Try the Result<usize> version first, then the plain usize version
    old_ns_fd_v1 = '            if let Some((symbol, _)) = obj.get_sym("__relibc_init_ns_fd") {\n                if let Ok(ns_fd) = redox_rt::current_namespace_fd() {\n                    unsafe {\n                        symbol.as_ptr().cast::<usize>().write(ns_fd);\n                    }\n                }\n            }'
    old_ns_fd_v2 = '            if let Some((symbol, _)) = obj.get_sym("__relibc_init_ns_fd") {\n                let ns_fd = redox_rt::current_namespace_fd();\n                if ns_fd != usize::MAX {\n                    unsafe {\n                        symbol.as_ptr().cast::<usize>().write(ns_fd);\n                    }\n                }\n            }'

    ns_fd_fallback = (
        ' else if let Some(addr) = obj.local_init_syms.ns_fd {\n'
        '                if let Ok(ns_fd) = redox_rt::current_namespace_fd() {\n'
        '                    unsafe {\n'
        '                        (addr as *mut usize).write(ns_fd);\n'
        '                    }\n'
        '                }\n'
        '            }'
    )

    old_ns_fd = None
    for candidate in [old_ns_fd_v1, old_ns_fd_v2]:
        if candidate in content:
            old_ns_fd = candidate
            break

    if old_ns_fd is None:
        print(f"WARNING: ns_fd injection block not found in {path}, skipping", file=sys.stderr)
        return False

    new_ns_fd = old_ns_fd + ns_fd_fallback

    if old_ns_fd not in content:
        print(f"WARNING: ns_fd injection block not found in {path}, skipping", file=sys.stderr)
        return False

    content = content.replace(old_ns_fd, new_ns_fd)

    # For environ, add .symtab fallback in the None arm of the diagnostic match block.
    # After run-init.patch, the environ injection is a match block with Some/None arms.
    old_environ_none = '''            None => {
                eprintln!(
                    "[ld.so environ-diag] __relibc_init_environ NOT FOUND in DSO,                      ld_so environ={:p} null={} count={}",
                    environ_ptr, environ_is_null, environ_count
                );
            }'''

    new_environ_none = '''            None => {
                // Try .symtab fallback for LOCAL symbol
                if let Some(addr) = obj.local_init_syms.environ {
                    eprintln!(
                        "[ld.so environ-diag] FOUND __relibc_init_environ via .symtab fallback at {:p}",
                        addr as *const u8
                    );
                    unsafe {
                        (addr as *mut *mut *mut c_char).write(environ_ptr);
                    }
                } else {
                    eprintln!(
                        "[ld.so environ-diag] __relibc_init_environ NOT FOUND in DSO (dynsym or symtab),                          ld_so environ={:p} null={} count={}",
                        environ_ptr, environ_is_null, environ_count
                    );
                }
            }'''

    if old_environ_none not in content:
        # Fallback: try matching the simple if-let pattern (in case run-init.patch is simplified later)
        old_environ_simple = '''        if let Some((symbol, _)) = obj.get_sym("__relibc_init_environ") {
            unsafe {
                symbol
                    .as_ptr()
                    .cast::<*mut *mut c_char>()
                    .write(platform::environ);
            }
        }'''
        new_environ_simple = old_environ_simple + '''\n        else if let Some(addr) = obj.local_init_syms.environ {
            unsafe {
                (addr as *mut *mut *mut c_char).write(platform::environ);
            }
        }'''
        if old_environ_simple in content:
            content = content.replace(old_environ_simple, new_environ_simple)
        else:
            print(f"WARNING: environ injection block not found in {path}, skipping", file=sys.stderr)
            return False
    else:
        content = content.replace(old_environ_none, new_environ_none)

    # Add CWD fallback after the existing CWD injection block.
    # The existing CWD block uses nested if-let for get_sym calls.
    # We add a fallback using local_init_syms when get_sym fails.
    old_cwd_close = '''                    }
                }
            }
        }

        obj.run_init();'''

    new_cwd_close = '''                    }
                }
            } else if obj.local_init_syms.cwd_ptr.is_some()
                   && obj.local_init_syms.cwd_len.is_some()
                   && obj.local_init_syms.cwd_fd.is_some() {
                // Fallback: CWD symbols are LOCAL, found via .symtab
                if let Some(cwd) = crate::platform::sys::path::clone_cwd() {
                    if let Ok(cwd_guard) = crate::platform::sys::path::current_dir() {
                        if let Some(ref cwd_obj) = *cwd_guard {
                            let raw_fd = cwd_obj.fd.as_raw_fd();
                            if let Ok(new_fd) = syscall::dup(raw_fd, b"") {
                                let cwd_leaked: &\'static str = alloc::boxed::Box::leak(cwd);
                                unsafe {
                                    (obj.local_init_syms.cwd_ptr.unwrap() as *mut usize).write(cwd_leaked.as_ptr() as usize);
                                    (obj.local_init_syms.cwd_len.unwrap() as *mut usize).write(cwd_leaked.len());
                                    (obj.local_init_syms.cwd_fd.unwrap() as *mut usize).write(new_fd);
                                }
                            }
                        }
                    }
                }
            }
        }

        obj.run_init();'''

    if old_cwd_close in content:
        content = content.replace(old_cwd_close, new_cwd_close)
    else:
        print(f"WARNING: CWD block close not found in {path}, skipping CWD fallback", file=sys.stderr)

    with open(path, 'w') as f:
        f.write(content)
    return True


def main():
    src_dir = sys.argv[1] if len(sys.argv) > 1 else "."

    dso_path = os.path.join(src_dir, "src/ld_so/dso.rs")
    linker_path = os.path.join(src_dir, "src/ld_so/linker.rs")

    ok = True
    if os.path.exists(dso_path):
        if not patch_dso_rs(dso_path):
            ok = False
    else:
        print(f"ERROR: {dso_path} not found", file=sys.stderr)
        ok = False

    if os.path.exists(linker_path):
        if not patch_linker_rs(linker_path):
            ok = False
    else:
        print(f"ERROR: {linker_path} not found", file=sys.stderr)
        ok = False

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
