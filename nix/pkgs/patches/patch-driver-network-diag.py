"""Add the igcd diagnostic resource to the upstream ResourceSync network scheme."""

import sys
from pathlib import Path

path = Path(sys.argv[1]) / "drivers/net/driver-network/src/lib.rs"
src = path.read_text()


def replace_once(old, new):
    global src
    if src.count(old) != 1:
        raise SystemExit(f"driver-network diagnostic patch: expected one match for {old!r}")
    src = src.replace(old, new, 1)


replace_once(
    "    fn write_packet(&mut self, buf: &[u8]) -> Result<usize>;",
    "    fn write_packet(&mut self, buf: &[u8]) -> Result<usize>;\n\n"
    "    /// Return driver-specific diagnostics as UTF-8 text.\n"
    "    fn diagnostic_info(&mut self) -> Vec<u8> { Vec::new() }",
)
replace_once("        Mac(Mac<T>),", "        Mac(Mac<T>),\n        Diag(Diag<T>),")
replace_once(
    '            "mac" => (\n',
    '            "diag" => (\n'
    "                NetworkResource::Diag(Diag(PhantomData)),\n"
    "                NewFdFlags::POSITIONED,\n"
    "            ),\n"
    '            "mac" => (\n',
)
src += """

struct Diag<T>(PhantomData<T>);

impl<T> std::fmt::Debug for Diag<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Diag").finish()
    }
}

impl<T: NetworkAdapter> ResourceSync for Diag<T> {
    type SchemeData = NetworkSchemeData<T>;
    type ResourceEnum = NetworkResource<T>;

    fn read(
        &mut self,
        scheme_data: &mut Self::SchemeData,
        buf: &mut [u8],
        offset: u64,
        _fcntl_flags: u32,
    ) -> Result<usize> {
        let data = scheme_data.adapter.diagnostic_info();
        let start = usize::try_from(offset).unwrap_or(usize::MAX).min(data.len());
        let remaining = &data[start..];
        let count = cmp::min(buf.len(), remaining.len());
        buf[..count].copy_from_slice(&remaining[..count]);
        Ok(count)
    }

    fn write(
        &mut self,
        _scheme_data: &mut Self::SchemeData,
        _buf: &[u8],
        _offset: u64,
        _fcntl_flags: u32,
    ) -> Result<usize> {
        Err(Error::new(EINVAL))
    }

    fn fpath(&mut self, _scheme_data: &mut Self::SchemeData, w: &mut FpathWriter) -> Result<()> {
        w.push_str("diag");
        Ok(())
    }

    fn fstat(&mut self, _scheme_data: &mut Self::SchemeData, stat: &mut Stat) -> Result<()> {
        stat.st_mode = MODE_FILE | 0o400;
        Ok(())
    }
}
"""
path.write_text(src)
print("Patched driver-network: added diagnostic resource")
