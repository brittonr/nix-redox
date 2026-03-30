"""Patch driver-network to support a 'diag' read path on network schemes.

Adds:
- diagnostic_info() method to NetworkAdapter trait (default: empty)
- Handle::Diag variant
- "diag" path in openat
- Read handler for Diag that calls diagnostic_info()
"""

import sys

path = sys.argv[1] + "/drivers/net/driver-network/src/lib.rs"

with open(path) as f:
    src = f.read()

# 1. Add diagnostic_info to NetworkAdapter trait
src = src.replace(
    '    fn write_packet(&mut self, buf: &[u8]) -> Result<usize>;',
    '    fn write_packet(&mut self, buf: &[u8]) -> Result<usize>;\n'
    '\n'
    '    /// Return diagnostic information as UTF-8 text.\n'
    '    /// Default: empty. Drivers override to provide register dumps.\n'
    '    fn diagnostic_info(&mut self) -> Vec<u8> { Vec::new() }\n'
)

# 2. Add Handle::Diag variant
src = src.replace(
    'enum Handle {\n    Data,\n    Mac,\n    SchemeRoot,\n}',
    'enum Handle {\n    Data,\n    Mac,\n    Diag,\n    SchemeRoot,\n}'
)

# 3. Add "diag" to openat match
src = src.replace(
    '            "mac" => (Handle::Mac, NewFdFlags::POSITIONED),',
    '            "mac" => (Handle::Mac, NewFdFlags::POSITIONED),\n'
    '            "diag" => (Handle::Diag, NewFdFlags::POSITIONED),'
)

# 4. Add Diag read handler (before the Data match in read)
src = src.replace(
    '            Handle::Data => {}',
    '            Handle::Data => {}\n'
    '            Handle::Diag => {\n'
    '                let data = self.adapter.diagnostic_info();\n'
    '                let start = cmp::min(offset as usize, data.len());\n'
    '                let remaining = &data[start..];\n'
    '                let i = cmp::min(buf.len(), remaining.len());\n'
    '                buf[..i].copy_from_slice(&remaining[..i]);\n'
    '                return Ok(i);\n'
    '            }',
    1  # only replace first occurrence (in the read method)
)

# 5. Add Diag to fpath match
src = src.replace(
    '            Handle::Mac { .. } => &b"mac"[..],',
    '            Handle::Mac { .. } => &b"mac"[..],\n'
    '            Handle::Diag { .. } => &b"diag"[..],'
)

# 6. Add Diag to fstat match
src = src.replace(
    '            Handle::Mac { .. } => {\n'
    '                stat.st_mode = MODE_FILE | 0o400;\n'
    '                stat.st_size = 6;\n'
    '            }',
    '            Handle::Mac { .. } => {\n'
    '                stat.st_mode = MODE_FILE | 0o400;\n'
    '                stat.st_size = 6;\n'
    '            }\n'
    '            Handle::Diag { .. } => {\n'
    '                stat.st_mode = MODE_FILE | 0o400;\n'
    '            }'
)

# 7. Handle Diag in write (return EINVAL, same as Mac)
src = src.replace(
    '            Handle::Mac { .. } => return Err(Error::new(EINVAL)),',
    '            Handle::Mac { .. } => return Err(Error::new(EINVAL)),\n'
    '            Handle::Diag { .. } => return Err(Error::new(EINVAL)),'
)

with open(path, 'w') as f:
    f.write(src)

print("Patched driver-network: added diag read path")
