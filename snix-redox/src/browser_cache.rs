//! Browser Fetch → serial → guest-owned immutable cache transport.
//!
//! The trusted release manifest pins transport.json; its SHA256 and size are
//! passed on the command line. Only files in that descriptor may be received.
//! This foreground CLI worker never runs inside a scheme-handler event loop.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};

use data_encoding::{BASE64, HEXLOWER};
use serde::Deserialize;
use sha2::{Digest, Sha256};

const PREFIX: &str = "@@SNIX_CACHE_V1@@";
pub const MAX_DESCRIPTOR: u64 = 4 * 1024 * 1024;
pub const MAX_OBJECT: u64 = 128 * 1024 * 1024;
pub const MAX_TRANSFER: u64 = 256 * 1024 * 1024;
pub const MAX_FILES: usize = 256;
pub const CHUNK_SIZE: usize = 8192;
// Base64 plus correlation metadata fits in 16 KiB. Exactly one frame may be
// outstanding; the descriptor/object/transfer budgets remain unchanged.
const MAX_LINE: usize = 16 * 1024;
const TARGET: &str = "x86_64-unknown-redox";

pub type Result<T, E = Box<dyn std::error::Error>> = std::result::Result<T, E>;

#[derive(clap::Args)]
pub struct ReceiveArgs {
    #[arg(long)]
    pub session: String,
    #[arg(long)]
    pub request: String,
    #[arg(long)]
    pub descriptor_sha256: String,
    #[arg(long)]
    pub descriptor_size: u64,
    #[arg(long)]
    pub package: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Object {
    pub path: String,
    pub sha256: String,
    pub size: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Package {
    pub store_path: String,
    pub files: Vec<Object>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Descriptor {
    pub version: u32,
    pub target: String,
    pub packages: BTreeMap<String, Package>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Frame {
    v: u32,
    session: String,
    request: String,
    seq: u64,
    op: String,
    #[serde(default)]
    index: Option<i64>,
    #[serde(default)]
    data: Option<String>,
}

struct Cleanup(PathBuf);
impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn is_hex(s: &str, size: usize) -> bool {
    s.len() == size && s.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

fn safe_path(s: &str) -> bool {
    !s.is_empty()
        && !s.contains('\\')
        && !s.bytes().any(|c| b":%?#".contains(&c))
        && s.split('/').all(|p| !p.is_empty() && p != "." && p != "..")
        && Path::new(s).components().all(|c| matches!(c, Component::Normal(_)))
}

pub fn validate_descriptor(descriptor: &Descriptor, package: &str) -> Result<()> {
    if descriptor.version != 1 || descriptor.target != TARGET {
        return Err("unsupported or non-Redox transport descriptor".into());
    }
    let p = descriptor.packages.get(package).ok_or("package not in curated descriptor")?;
    nix_compat::store_path::StorePath::<String>::from_absolute_path(p.store_path.as_bytes())?;
    if p.files.is_empty() || p.files.len() > MAX_FILES {
        return Err("closure file count exceeds limit".into());
    }
    let mut paths = BTreeSet::new();
    let mut bytes = 0u64;
    for file in &p.files {
        if !safe_path(&file.path) || !is_hex(&file.sha256, 64) || file.size > MAX_OBJECT {
            return Err("invalid cache file identity or size".into());
        }
        if !paths.insert(file.path.as_str()) {
            return Err("duplicate cache file path".into());
        }
        bytes = bytes.checked_add(file.size).ok_or("closure size overflow")?;
    }
    if bytes > MAX_TRANSFER {
        return Err("closure exceeds transfer/storage budget".into());
    }
    for required in ["packages.json", "closure.json", "nix-cache-info"] {
        if !paths.contains(required) {
            return Err(format!("closure lacks {required}").into());
        }
    }
    Ok(())
}

fn hash_file(path: &Path, object: &Object) -> Result<bool> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(e.into()),
    };
    if file.metadata()?.len() != object.size {
        return Ok(false);
    }
    let mut hash = Sha256::new();
    let mut buf = [0u8; 16384];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 { break; }
        hash.update(&buf[..n]);
    }
    Ok(HEXLOWER.encode(&hash.finalize()) == object.sha256)
}

struct Protocol<'a, F, W> {
    args: &'a ReceiveArgs,
    read: F,
    write: W,
    seq: u64,
    received: u64,
    reused: u64,
}

impl<F: FnMut() -> Result<String>, W: Write> Protocol<'_, F, W> {
    fn reply(&mut self, op: &str, extra: serde_json::Value) -> Result<()> {
        let value = serde_json::json!({"v":1,"session":self.args.session,
            "request":self.args.request,"seq":self.seq,"op":op,"detail":extra});
        writeln!(self.write, "\n{PREFIX}{value}")?;
        self.write.flush()?;
        Ok(())
    }

    fn frame(&mut self, expected: &str) -> Result<Frame> {
        let line = (self.read)()?;
        if line.len() > MAX_LINE { return Err("oversized serial frame".into()); }
        let frame: Frame = serde_json::from_str(line.trim())?;
        if frame.v != 1 || frame.session != self.args.session || frame.request != self.args.request
            || frame.seq != self.seq + 1 {
            return Err("serial session/request/sequence mismatch".into());
        }
        self.seq = frame.seq;
        if frame.op == "cancel" { return Err("transfer cancelled".into()); }
        if frame.op != expected { return Err(format!("expected {expected} frame").into()); }
        Ok(frame)
    }

    fn object(&mut self, object: &Object, index: i64, objects: &Path, stage: &Path) -> Result<PathBuf> {
        let begin = self.frame("begin")?;
        if begin.index != Some(index) { return Err("object index mismatch".into()); }
        let destination = objects.join(&object.sha256);
        if hash_file(&destination, object)? {
            self.reused += object.size;
            self.reply("have", serde_json::json!({"index":index}))?;
            return Ok(destination);
        }
        if destination.exists() { fs::remove_file(&destination)?; }
        self.reply("need", serde_json::json!({"index":index}))?;
        let partial = stage.join("object.partial");
        let mut file = File::create(&partial)?;
        let mut hash = Sha256::new();
        let mut size = 0u64;
        while size < object.size {
            let chunk = self.frame("chunk")?;
            let encoded = chunk.data.ok_or("missing chunk data")?;
            if encoded.len() > CHUNK_SIZE.div_ceil(3) * 4 { return Err("chunk exceeds limit".into()); }
            let bytes = BASE64.decode(encoded.as_bytes())?;
            if bytes.is_empty() || bytes.len() > CHUNK_SIZE || size + bytes.len() as u64 > object.size {
                return Err("short/oversized object chunk".into());
            }
            file.write_all(&bytes)?;
            hash.update(&bytes);
            size += bytes.len() as u64;
            self.received += bytes.len() as u64;
            self.reply("ok", serde_json::json!({"offset":size}))?;
        }
        self.frame("end")?;
        if HEXLOWER.encode(&hash.finalize()) != object.sha256 {
            return Err("cache object SHA256 mismatch".into());
        }
        file.sync_all()?;
        drop(file);
        fs::rename(&partial, &destination)?;
        self.reply("ok", serde_json::json!({"size":size}))?;
        Ok(destination)
    }
}

/// Testable protocol entry point. `root` is private guest-managed storage.
/// The caller must own the serial foreground exclusively for the invocation.
pub fn receive_with<F: FnMut() -> Result<String>, W: Write>(
    args: &ReceiveArgs, root: &Path, read: F, write: W,
) -> Result<()> {
    if !is_hex(&args.session, 32) || !is_hex(&args.request, 32)
        || !is_hex(&args.descriptor_sha256, 64)
        || args.descriptor_size == 0 || args.descriptor_size > MAX_DESCRIPTOR {
        return Err("invalid receiver identity/descriptor bound".into());
    }
    fs::create_dir_all(root)?;
    // A reboot/closed serial owner may leave only unadvertised staging files.
    // No installed cache view is kept here: reusable data lives in objects/.
    let stage = root.join("partial");
    if stage.exists() { fs::remove_dir_all(&stage)?; }
    fs::create_dir(&stage)?;
    let _cleanup = Cleanup(stage.clone());
    let objects = root.join("objects");
    fs::create_dir_all(&objects)?;
    let started = Instant::now();
    let mut protocol = Protocol { args, read, write, seq: 0, received: 0, reused: 0 };
    let result = (|| -> Result<()> {
        protocol.reply("ready", serde_json::json!({"chunkSize":CHUNK_SIZE}))?;
        let descriptor = Object { path: "transport.json".into(), sha256: args.descriptor_sha256.clone(), size: args.descriptor_size };
        let descriptor_path = protocol.object(&descriptor, -1, &objects, &stage)?;
        let descriptor: Descriptor = serde_json::from_reader(File::open(descriptor_path)?)?;
        validate_descriptor(&descriptor, &args.package)?;
        let package = &descriptor.packages[&args.package];
        // Keep at most the selected closure and this pinned descriptor. This
        // bounds persistent immutable storage, including after interrupted runs.
        let mut keep: BTreeSet<&str> = package.files.iter().map(|f| f.sha256.as_str()).collect();
        keep.insert(&args.descriptor_sha256);
        for entry in fs::read_dir(&objects)? {
            let entry = entry?;
            if !keep.contains(entry.file_name().to_str().unwrap_or("")) {
                fs::remove_file(entry.path())?;
            }
        }
        let view = stage.join("cache");
        fs::create_dir(&view)?;
        for (index, object) in package.files.iter().enumerate() {
            let source = protocol.object(object, index as i64, &objects, &stage)?;
            let destination = view.join(&object.path);
            fs::create_dir_all(destination.parent().ok_or("invalid cache path")?)?;
            // Redox filesystems need not implement hard links. Copying here is
            // bounded by the closure budget and still happens only in the guest.
            fs::copy(source, destination)?;
        }
        protocol.frame("install")?;
        // The installer checks the advertised root and all references, validates
        // NAR identities/content, and publishes store paths only after hashing.
        let source = crate::cache_source::CacheSource::Local(view);
        let index = source.read_index()?;
        if index.version != 2 { return Err("browser cache requires package-index v2".into()); }
        let entry = index.packages.get(&args.package).ok_or("package missing from cache index")?;
        if entry.store_path != package.store_path { return Err("descriptor/index root mismatch".into()); }
        preflight(&source, package, &args.package)?;
        crate::install::install_recursive(&args.package, &source)?;
        protocol.reply("installed", serde_json::json!({"storePath":package.store_path,
            "receivedBytes":protocol.received,"reusedBytes":protocol.reused,
            "elapsedMs":started.elapsed().as_millis()}))?;
        Ok(())
    })();
    if let Err(error) = &result {
        let _ = protocol.reply("error", serde_json::json!({"message":error.to_string()}));
    }
    result
}

/// Production serial reader has a bounded queue, line length and idle timeout.
/// EOF, short objects and cancellation unwind staging before returning to Bash.
pub fn receive(args: &ReceiveArgs) -> Result<()> {
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut reader = BufReader::new(stdin.lock());
        loop {
            let mut bytes = Vec::with_capacity(MAX_LINE);
            let result = reader.by_ref().take((MAX_LINE + 1) as u64).read_until(b'\n', &mut bytes);
            let line = match result {
                Ok(0) => Err("serial EOF".to_string()),
                Ok(_) if bytes.len() > MAX_LINE || !bytes.ends_with(b"\n") => Err("oversized/short serial line".to_string()),
                Ok(_) => String::from_utf8(bytes).map_err(|e| e.to_string()),
                Err(e) => Err(e.to_string()),
            };
            let failed = line.is_err();
            if tx.send(line).is_err() || failed { break; }
        }
    });
    receive_with(args, Path::new("/nix/var/snix/browser-cache"),
        || rx.recv_timeout(Duration::from_secs(60))
            .map_err(|_| "serial transfer idle timeout/disconnected".into())
            .and_then(|line| line.map_err(Into::into)),
        io::stdout().lock())
}

#[derive(Deserialize)]
struct Closure {
    version: u32,
    target: String,
    roots: BTreeMap<String, String>,
    paths: BTreeMap<String, ClosurePath>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClosurePath {
    references: Vec<String>,
    compatibility: crate::local_cache::Compatibility,
    nar_hash: String,
    nar_size: u64,
    file_size: u64,
    url: String,
}

/// Independently tie every reached narinfo and NAR to the pinned inventory.
/// Missing dependencies/wrong targets are rejected before any store mutation.
fn preflight(source: &crate::cache_source::CacheSource, package: &Package, name: &str) -> Result<()> {
    let view = match source {
        crate::cache_source::CacheSource::Local(path) => path,
        _ => return Err("browser transfer requires a local guest cache".into()),
    };
    let closure: Closure = serde_json::from_reader(File::open(view.join("closure.json"))?)?;
    if closure.version != 1 || closure.target != TARGET || closure.roots.get(name) != Some(&package.store_path) {
        return Err("closure target/root mismatch".into());
    }
    let files: BTreeMap<&str, &Object> = package.files.iter().map(|f| (f.path.as_str(), f)).collect();
    let mut seen = BTreeSet::new();
    let mut todo = vec![package.store_path.clone()];
    while let Some(path) = todo.pop() {
        if !seen.insert(path.clone()) { continue; }
        if seen.len() > MAX_FILES { return Err("closure path count exceeds limit".into()); }
        let record = closure.paths.get(&path).ok_or_else(|| format!("missing closure dependency: {path}"))?;
        let compatibility = &record.compatibility;
        if compatibility.version != 1 || compatibility.evidence.trim().is_empty()
            || !match compatibility.kind.as_str() {
                "native" => compatibility.target == TARGET,
                "script" | "data" => compatibility.target == "any",
                _ => false,
            } {
            return Err(format!("wrong-target/unproven closure dependency: {path}").into());
        }
        let sp = nix_compat::store_path::StorePath::<String>::from_absolute_path(path.as_bytes())?;
        let narinfo_name = format!("{}.narinfo", nix_compat::nixbase32::encode(sp.digest()));
        if !files.contains_key(narinfo_name.as_str()) { return Err("narinfo absent from pinned inventory".into()); }
        let info = source.fetch_narinfo(&sp)?;
        let payload = files.get(record.url.as_str()).ok_or("NAR absent from pinned inventory")?;
        let references: BTreeSet<String> = info.references.iter().map(|p| p.to_absolute_path()).collect();
        let declared: BTreeSet<String> = record.references.iter().cloned().collect();
        if !safe_path(&record.url) || info.url != record.url.as_str()
            || record.nar_hash != format!("sha256:{}", HEXLOWER.encode(&info.nar_hash))
            || record.nar_size != info.nar_size || record.file_size != payload.size
            || info.file_size != Some(payload.size) || references != declared {
            return Err(format!("closure/narinfo/pinned inventory mismatch: {path}").into());
        }
        todo.extend(references);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (ReceiveArgs, Vec<u8>, Object) {
        let object = Object { path: "packages.json".into(), sha256: HEXLOWER.encode(&Sha256::digest(b"good")), size: 4 };
        let value = serde_json::json!({"version":1,"target":TARGET,"packages":{"fd":{
            "storePath":"/nix/store/00000000000000000000000000000000-fd-1",
            "files":[{"path":object.path,"sha256":object.sha256,"size":object.size},
                {"path":"closure.json","sha256":"0".repeat(64),"size":0},
                {"path":"nix-cache-info","sha256":"0".repeat(64),"size":0}]}}});
        let bytes = serde_json::to_vec(&value).unwrap();
        let args = ReceiveArgs { session: "a".repeat(32), request: "b".repeat(32),
            descriptor_sha256: HEXLOWER.encode(&Sha256::digest(&bytes)),
            descriptor_size: bytes.len() as u64, package: "fd".into() };
        (args, bytes, object)
    }

    fn push(lines: &mut Vec<String>, args: &ReceiveArgs, op: &str, extra: serde_json::Value) {
        let mut frame = serde_json::json!({"v":1,"session":args.session,"request":args.request,
            "seq":lines.len() + 1,"op":op});
        frame.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        lines.push(frame.to_string());
    }

    fn descriptor_frames(args: &ReceiveArgs, bytes: &[u8]) -> Vec<String> {
        let mut lines = Vec::new();
        push(&mut lines, args, "begin", serde_json::json!({"index":-1}));
        for chunk in bytes.chunks(CHUNK_SIZE) {
            push(&mut lines, args, "chunk", serde_json::json!({"data":BASE64.encode(chunk)}));
        }
        push(&mut lines, args, "end", serde_json::json!({}));
        lines
    }

    fn run(args: &ReceiveArgs, root: &Path, lines: Vec<String>) -> (Result<()>, Vec<u8>) {
        let mut input = lines.into_iter();
        let mut output = Vec::new();
        let result = receive_with(args, root,
            || input.next().ok_or_else(|| "short serial input".into()), &mut output);
        (result, output)
    }

    #[test]
    fn short_transfer_cleans_partial_and_never_publishes_object() {
        let (args, bytes, object) = fixture();
        let root = tempfile::tempdir().unwrap();
        let mut lines = descriptor_frames(&args, &bytes);
        push(&mut lines, &args, "begin", serde_json::json!({"index":0}));
        push(&mut lines, &args, "chunk", serde_json::json!({"data":BASE64.encode(b"g")}));
        let (result, output) = run(&args, root.path(), lines);
        assert!(result.is_err());
        assert!(!root.path().join("partial").exists());
        assert!(!root.path().join("objects").join(object.sha256).exists());
        assert!(String::from_utf8(output).unwrap().contains("short serial input"));
    }

    #[test]
    fn bad_hash_is_not_published() {
        let (args, bytes, object) = fixture();
        let root = tempfile::tempdir().unwrap();
        let mut lines = descriptor_frames(&args, &bytes);
        push(&mut lines, &args, "begin", serde_json::json!({"index":0}));
        push(&mut lines, &args, "chunk", serde_json::json!({"data":BASE64.encode(b"evil")}));
        push(&mut lines, &args, "end", serde_json::json!({}));
        let (result, _) = run(&args, root.path(), lines);
        assert!(result.unwrap_err().to_string().contains("SHA256 mismatch"));
        assert!(!root.path().join("objects").join(object.sha256).exists());
        assert!(!root.path().join("partial").exists());
    }

    #[test]
    fn maximum_chunk_fits_frame_and_oversized_chunk_is_not_published() {
        for size in [CHUNK_SIZE, CHUNK_SIZE + 1] {
            let (mut args, bytes, _) = fixture();
            let data = vec![b'x'; size];
            let hash = HEXLOWER.encode(&Sha256::digest(&data));
            let mut descriptor: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            descriptor["packages"]["fd"]["files"][0]["size"] = size.into();
            descriptor["packages"]["fd"]["files"][0]["sha256"] = hash.clone().into();
            let bytes = serde_json::to_vec(&descriptor).unwrap();
            args.descriptor_size = bytes.len() as u64;
            args.descriptor_sha256 = HEXLOWER.encode(&Sha256::digest(&bytes));
            let mut lines = descriptor_frames(&args, &bytes);
            push(&mut lines, &args, "begin", serde_json::json!({"index":0}));
            push(&mut lines, &args, "chunk", serde_json::json!({"data":BASE64.encode(&data)}));
            push(&mut lines, &args, "end", serde_json::json!({}));
            assert!(lines.iter().all(|line| line.len() + 1 <= MAX_LINE));
            let root = tempfile::tempdir().unwrap();
            let (result, _) = run(&args, root.path(), lines);
            let error = result.unwrap_err().to_string();
            let destination = root.path().join("objects").join(&hash);
            if size == CHUNK_SIZE {
                assert!(error.contains("short serial input"), "{error}");
                assert_eq!(fs::read(destination).unwrap(), data);
            } else {
                assert!(error.contains("oversized object chunk"), "{error}");
                assert!(!destination.exists());
            }
            assert!(!root.path().join("partial").exists());
        }
    }

    #[test]
    fn cancel_removes_stale_and_current_staging() {
        let (args, _, _) = fixture();
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("partial")).unwrap();
        fs::write(root.path().join("partial/old-object"), b"half").unwrap();
        let mut lines = Vec::new();
        push(&mut lines, &args, "cancel", serde_json::json!({}));
        let (result, _) = run(&args, root.path(), lines);
        assert!(result.unwrap_err().to_string().contains("cancelled"));
        assert!(!root.path().join("partial").exists());
    }

    #[test]
    fn old_session_is_rejected() {
        let (args, _, _) = fixture();
        let root = tempfile::tempdir().unwrap();
        let line = serde_json::json!({"v":1,"session":"0".repeat(32),
            "request":args.request,"seq":1,"op":"begin","index":-1}).to_string();
        let (result, _) = run(&args, root.path(), vec![line]);
        assert!(result.unwrap_err().to_string().contains("session/request/sequence mismatch"));
    }

    #[test]
    fn descriptor_rejects_linux_and_traversal() {
        let (_, bytes, _) = fixture();
        let mut descriptor: Descriptor = serde_json::from_slice(&bytes).unwrap();
        descriptor.target = "x86_64-linux".into();
        assert!(validate_descriptor(&descriptor, "fd").is_err());
        descriptor.target = TARGET.into();
        descriptor.packages.get_mut("fd").unwrap().files[0].path = "../packages.json".into();
        assert!(validate_descriptor(&descriptor, "fd").is_err());
    }

    #[test]
    fn verified_descriptor_is_reused_but_corruption_is_not() {
        let (args, bytes, _) = fixture();
        let root = tempfile::tempdir().unwrap();
        let lines = descriptor_frames(&args, &bytes);
        let (result, _) = run(&args, root.path(), lines);
        assert!(result.is_err()); // descriptor complete, selected objects absent
        let mut reuse = Vec::new();
        push(&mut reuse, &args, "begin", serde_json::json!({"index":-1}));
        push(&mut reuse, &args, "cancel", serde_json::json!({}));
        let (_, output) = run(&args, root.path(), reuse);
        assert!(String::from_utf8(output).unwrap().contains("\"op\":\"have\""));
        fs::write(root.path().join("objects").join(&args.descriptor_sha256), vec![0; bytes.len()]).unwrap();
        let lines = descriptor_frames(&args, &bytes);
        let (_, output) = run(&args, root.path(), lines);
        assert!(String::from_utf8(output).unwrap().contains("\"op\":\"need\""));
        let pinned = fs::read(root.path().join("objects").join(&args.descriptor_sha256)).unwrap();
        assert_eq!(pinned, bytes);
    }
    #[test]
    fn preflight_rejects_missing_transitive_dependency_before_install() {
        let root = tempfile::tempdir().unwrap();
        let store_path = "/nix/store/00000000000000000000000000000000-fd-1";
        let dependency = "/nix/store/11111111111111111111111111111111-runtime-1";
        let payload = format!("nar/{}.nar.zst", "0".repeat(64));
        let narinfo = format!("StorePath: {store_path}\nURL: {payload}\nCompression: zstd\nNarHash: sha256:{}\nNarSize: 0\nFileHash: sha256:{}\nFileSize: 0\nReferences: {}\n", "0".repeat(52), "0".repeat(52), dependency.trim_start_matches("/nix/store/"));
        fs::write(root.path().join("00000000000000000000000000000000.narinfo"), narinfo).unwrap();
        let closure = serde_json::json!({"version":1,"target":TARGET,"roots":{"fd":store_path},
            "paths":{(store_path):{"references":[dependency],"compatibility":{"version":1,
                "kind":"native","target":TARGET,"evidence":"test build declaration"},
                "narHash":format!("sha256:{}", "0".repeat(64)),"narSize":0,"fileSize":0,"url":payload}}});
        fs::write(root.path().join("closure.json"), serde_json::to_vec(&closure).unwrap()).unwrap();
        let package = Package { store_path: store_path.into(), files: vec![
            Object { path: "00000000000000000000000000000000.narinfo".into(), sha256: "0".repeat(64), size: 0 },
            Object { path: payload, sha256: "0".repeat(64), size: 0 }] };
        let source = crate::cache_source::CacheSource::Local(root.path().into());
        let error = preflight(&source, &package, "fd").unwrap_err().to_string();
        assert!(error.contains("missing closure dependency"), "{error}");
    }

}
