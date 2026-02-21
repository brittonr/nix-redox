//! FUSE protocol definitions for virtio-fs.
//!
//! The virtio-fs device speaks the standard Linux FUSE protocol over virtqueues.
//! The host runs virtiofsd which translates FUSE ops to host filesystem ops.
//!
//! References:
//! - https://docs.oasis-open.org/virtio/virtio/v1.2/cs01/virtio-v1.2-cs01.html#x1-45900011
//! - Linux include/uapi/linux/fuse.h

use static_assertions::const_assert_eq;

// ============================================================================
// FUSE opcodes
// ============================================================================

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FuseOpcode {
    Lookup = 1,
    Forget = 2,
    Getattr = 3,
    // Setattr = 4,
    // Readlink = 5,
    // Symlink = 6,
    // Mknod = 8,
    // Mkdir = 9,
    // Unlink = 10,
    // Rmdir = 11,
    // Rename = 12,
    // Link = 13,
    Open = 14,
    Read = 15,
    // Write = 16,
    Statfs = 17,
    Release = 18,
    // Fsync = 20,
    // Setxattr = 21,
    // Getxattr = 22,
    // Listxattr = 23,
    // Removexattr = 24,
    Flush = 25,
    Init = 26,
    Opendir = 27,
    Readdir = 28,
    Releasedir = 29,
    // Fsyncdir = 30,
    // Access = 34,
    // Create = 35,
    // Batchforget = 42,
    Readdirplus = 44,
    // Setupmapping = 48,
    // Removemapping = 49,
}

// ============================================================================
// FUSE wire types (must match Linux kernel FUSE ABI exactly)
// ============================================================================

/// FUSE request header — sent from guest to host.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseInHeader {
    pub len: u32,
    pub opcode: u32,
    pub unique: u64,
    pub nodeid: u64,
    pub uid: u32,
    pub gid: u32,
    pub pid: u32,
    pub total_extlen: u16,
    pub padding: u16,
}

const_assert_eq!(core::mem::size_of::<FuseInHeader>(), 40);

/// FUSE response header — returned from host to guest.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseOutHeader {
    pub len: u32,
    pub error: i32,
    pub unique: u64,
}

const_assert_eq!(core::mem::size_of::<FuseOutHeader>(), 16);

/// FUSE_INIT request body.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseInitIn {
    pub major: u32,
    pub minor: u32,
    pub max_readahead: u32,
    pub flags: u32,
    pub flags2: u32,
    pub unused: [u32; 11],
}

/// FUSE_INIT response body.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseInitOut {
    pub major: u32,
    pub minor: u32,
    pub max_readahead: u32,
    pub flags: u32,
    pub max_background: u16,
    pub congestion_threshold: u16,
    pub max_write: u32,
    pub time_gran: u32,
    pub max_pages: u16,
    pub map_alignment: u16,
    pub flags2: u32,
    pub max_stack_depth: u32,
    pub unused: [u32; 6],
}

/// FUSE_GETATTR request body.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseGetattrIn {
    pub getattr_flags: u32,
    pub dummy: u32,
    pub fh: u64,
}

/// FUSE file attributes (like struct stat).
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct FuseAttr {
    pub ino: u64,
    pub size: u64,
    pub blocks: u64,
    pub atime: u64,
    pub mtime: u64,
    pub ctime: u64,
    pub atimensec: u32,
    pub mtimensec: u32,
    pub ctimensec: u32,
    pub mode: u32,
    pub nlink: u32,
    pub uid: u32,
    pub gid: u32,
    pub rdev: u32,
    pub blksize: u32,
    pub flags: u32,
}

/// FUSE_GETATTR response body.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseAttrOut {
    pub attr_valid: u64,
    pub attr_valid_nsec: u32,
    pub dummy: u32,
    pub attr: FuseAttr,
}

/// FUSE_LOOKUP response body (same as FUSE_ENTRY).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseEntryOut {
    pub nodeid: u64,
    pub generation: u64,
    pub entry_valid: u64,
    pub attr_valid: u64,
    pub entry_valid_nsec: u32,
    pub attr_valid_nsec: u32,
    pub attr: FuseAttr,
}

/// FUSE_OPEN request body.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseOpenIn {
    pub flags: u32,
    pub open_flags: u32,
}

/// FUSE_OPEN response body.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseOpenOut {
    pub fh: u64,
    pub open_flags: u32,
    pub backing_id: i32,
}

/// FUSE_READ request body.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseReadIn {
    pub fh: u64,
    pub offset: u64,
    pub size: u32,
    pub read_flags: u32,
    pub lock_owner: u64,
    pub flags: u32,
    pub padding: u32,
}

/// FUSE_RELEASE request body.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseReleaseIn {
    pub fh: u64,
    pub flags: u32,
    pub release_flags: u32,
    pub lock_owner: u64,
}

/// FUSE_STATFS response body.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseStatfsOut {
    pub st: FuseKstatfs,
}

/// FUSE filesystem stats (like struct statfs).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseKstatfs {
    pub blocks: u64,
    pub bfree: u64,
    pub bavail: u64,
    pub files: u64,
    pub ffree: u64,
    pub bsize: u32,
    pub namelen: u32,
    pub frsize: u32,
    pub padding: u32,
    pub spare: [u32; 6],
}

/// FUSE READDIRPLUS entry (inline in readdir response).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseDirentplus {
    pub entry_out: FuseEntryOut,
    pub dirent: FuseDirent,
}

/// FUSE directory entry (inline in readdir response).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FuseDirent {
    pub ino: u64,
    pub off: u64,
    pub namelen: u32,
    pub typ: u32,
    // name bytes follow (variable length, padded to 8 bytes)
}

// ============================================================================
// FUSE constants
// ============================================================================

/// FUSE kernel protocol version we speak.
pub const FUSE_KERNEL_VERSION: u32 = 7;
/// FUSE kernel minor version (7.39 is current as of Linux 6.x).
pub const FUSE_KERNEL_MINOR_VERSION: u32 = 39;

/// Maximum size for read/write data transfers.
pub const FUSE_MAX_PAGES: u32 = 256; // 1 MiB with 4K pages

// S_IF* mode constants (POSIX).
pub const S_IFMT: u32 = 0o170000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFLNK: u32 = 0o120000;

/// Round up to FUSE dirent alignment (8 bytes).
pub const fn fuse_dirent_align(x: usize) -> usize {
    (x + 7) & !7
}

/// Size of a FuseDirent plus its name, padded to alignment.
pub const fn fuse_dirent_size(namelen: usize) -> usize {
    fuse_dirent_align(core::mem::size_of::<FuseDirent>() + namelen)
}
