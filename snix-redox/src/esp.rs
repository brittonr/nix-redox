//! Replace an existing FAT32 fallback loader without modifying its live chain in place.
//!
//! The caller must own the unmounted volume exclusively and keep the source stable.
//! Durability depends on the backend honoring sync and on the directory-sector write
//! being atomic. In particular, Redox disk schemes can acknowledge sync without a
//! device cache flush. Interrupted operations can leave orphan clusters or diverging
//! FAT copies; this is not a journal or a repair tool.
//! Only a seeded volume with the EFI/BOOT/BOOTX64.EFI short-name path is
//! supported. This code neither creates directories nor authenticates EFI bytes.

use std::fs::{File, OpenOptions};
use std::io::{self, ErrorKind, Read, Seek, SeekFrom, Write};
use std::path::Path;

const MAX_SECTOR: usize = 4096;
const FAT_MASK: u32 = 0x0fff_ffff;
const EOC: u32 = 0x0fff_fff8;
const LAST_DATA_CLUSTER: u32 = 0x0fff_ffef;
const PATH: [&[u8; 11]; 3] = [b"EFI        ", b"BOOT       ", b"BOOTX64 EFI"];
type Sector = [u8; MAX_SECTOR];
type FatLink = (u32, u32); // cluster, current FAT value

pub(crate) fn install(esp: &Path, efi: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let mut source = File::open(efi)?;
    let metadata = source.metadata()?;
    let size =
        u32::try_from(metadata.len()).map_err(|_| invalid("EFI file exceeds FAT32 size limit"))?;
    if !metadata.is_file() || size == 0 {
        return Err(invalid("EFI source must be a nonempty regular file").into());
    }

    let mut volume = Volume::open(esp)?;
    let mut fat = FatReader::new();
    let (slot, mut old_chain) = volume.find_loader(&mut fat)?;
    let old_size = le32(&slot.entry, 28);
    if old_size == size
        && volume.transfer(
            &mut source,
            size,
            old_chain.iter().map(|&(cluster, _)| cluster),
            false,
        )?
    {
        return Ok(());
    }
    let new_chain = volume.find_free(&mut fat, volume.clusters_for(size))?;
    let mut directory_sector = [0; MAX_SECTOR];
    volume.read_sector(slot.sector, &mut directory_sector)?;
    if directory_sector[slot.offset..slot.offset + 32] != slot.entry {
        return Err(invalid("loader directory entry changed during inspection").into());
    }

    // FSInfo is advisory. Mark counts/hints unknown before changing any FAT entry
    // rather than maintaining a second piece of allocation state across a failure.
    volume.invalidate_fsinfo()?;
    volume.file.sync_all()?;
    volume.transfer(&mut source, size, new_chain.iter().copied(), true)?;
    volume.change_fat(new_chain.len(), |i| {
        (new_chain[i], 0, next_link(&new_chain, i))
    })?;
    volume.file.sync_all()?;
    volume.verify_chain(&new_chain)?;
    if !volume.transfer(&mut source, size, new_chain.iter().copied(), false)? {
        return Err(invalid("staged EFI payload failed readback").into());
    }

    let mut current = [0; MAX_SECTOR];
    volume.read_sector(slot.sector, &mut current)?;
    if current != directory_sector {
        return Err(invalid("loader directory sector changed before publication").into());
    }
    let entry = &mut directory_sector[slot.offset..slot.offset + 32];
    let first = new_chain[0];
    entry[20..22].copy_from_slice(&((first >> 16) as u16).to_le_bytes());
    entry[26..28].copy_from_slice(&(first as u16).to_le_bytes());
    entry[28..32].copy_from_slice(&size.to_le_bytes());

    // This is the only write that changes which chain firmware can find. After
    // attempting it, an error is not evidence that the old loader is still selected.
    (|| -> io::Result<()> {
        volume.write_sector(slot.sector, &directory_sector)?;
        volume.file.sync_all()?;
        volume.read_sector(slot.sector, &mut current)?;
        if current != directory_sector {
            return Err(invalid("published loader directory sector failed readback"));
        }
        volume.verify_chain(&new_chain)
    })()
    .map_err(|e| stage_error("EFI publication attempted; old chain retained", e))?;

    // Sort the validated old links so reclamation can batch edits by FAT sector.
    old_chain.sort_unstable_by_key(|&(cluster, _)| cluster);
    (|| -> io::Result<()> {
        volume.change_fat(old_chain.len(), |i| {
            let (cluster, previous) = old_chain[i];
            (cluster, previous, 0)
        })?;
        volume.file.sync_all()
    })()
    .map_err(|e| stage_error("replacement EFI verified; old chain cleanup failed", e))?;
    Ok(())
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(ErrorKind::InvalidData, message)
}

fn stage_error(stage: &str, error: io::Error) -> io::Error {
    io::Error::new(error.kind(), format!("{stage}: {error}"))
}

fn le16(bytes: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([bytes[at], bytes[at + 1]])
}

fn le32(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

fn next_link(chain: &[u32], index: usize) -> u32 {
    chain.get(index + 1).copied().unwrap_or(FAT_MASK)
}

struct Volume {
    file: File,
    sector_size: usize,
    sectors: u64,
    sectors_per_cluster: u64,
    data_start: u64,
    fat_start: u64,
    fat_sectors: u64,
    first_fat: u64,
    fat_copies: u64,
    last_cluster: u32,
    root_cluster: u32,
    fsinfo: [Option<u64>; 2],
}

impl Volume {
    fn open(path: &Path) -> io::Result<Self> {
        let mut file = OpenOptions::new().read(true).write(true).open(path)?;
        let metadata = file.metadata()?;
        // The Redox scheme presents disk/partition handles as regular files. For
        // its explicit disk paths, st_blksize is the device logical sector size,
        // not a filesystem I/O hint. Do not issue a 512-byte probe on a 4Kn disk.
        #[cfg(target_os = "redox")]
        let device_sector = {
            use std::os::unix::fs::MetadataExt;
            let raw = path.to_str().and_then(|path| {
                path.strip_prefix("/scheme/")
                    .and_then(|path| path.split_once('/'))
                    .or_else(|| path.split_once(':'))
                    .filter(|(scheme, _)| *scheme == "disk" || scheme.starts_with("disk."))
            });
            if let Some((_, name)) = raw {
                let partition = name.trim_start_matches('/').split_once('p');
                if !partition.is_some_and(|(disk, part)| {
                    !disk.is_empty()
                        && !part.is_empty()
                        && disk.bytes().all(|b| b.is_ascii_digit())
                        && part.bytes().all(|b| b.is_ascii_digit())
                }) {
                    return Err(invalid(
                        "choose an explicit Redox disk partition, not a disk",
                    ));
                }
                Some(metadata.blksize() as usize)
            } else {
                None
            }
        };
        #[cfg(not(target_os = "redox"))]
        let device_sector: Option<usize> = None;
        if !metadata.is_file() && device_sector.is_none() {
            return Err(invalid("expected a FAT32 image or a Redox disk partition"));
        }
        let probe_size = device_sector.unwrap_or(512);
        if !matches!(probe_size, 512 | 1024 | 2048 | 4096) || metadata.len() < probe_size as u64 {
            return Err(invalid("unsupported device sector size or truncated ESP"));
        }
        let mut boot = [0; MAX_SECTOR];
        read_full(&mut file, &mut boot[..probe_size])?;
        let sector_size = usize::from(le16(&boot, 11));
        let sectors_per_cluster = u64::from(boot[13]);
        let reserved = u64::from(le16(&boot, 14));
        let fats = u64::from(boot[16]);
        let sectors = u64::from(le32(&boot, 32));
        let fat_sectors = u64::from(le32(&boot, 36));
        let flags = le16(&boot, 40);
        if !(boot[0] == 0xe9 || (boot[0] == 0xeb && boot[2] == 0x90))
            || boot[510..512] != [0x55, 0xaa]
            || !matches!(sector_size, 512 | 1024 | 2048 | 4096)
            || device_sector.is_some_and(|size| size != sector_size)
            || !sectors_per_cluster.is_power_of_two()
            || sectors_per_cluster > 128
            || reserved == 0
            || !matches!(fats, 1 | 2)
            || le16(&boot, 17) != 0 // FAT12/16 root entry count
            || le16(&boot, 19) != 0 // FAT12/16 total sectors
            || le16(&boot, 22) != 0 // FAT12/16 FAT length
            || fat_sectors == 0
            || flags & !0x008f != 0
            || le16(&boot, 42) != 0 // FAT32 version 0.0
            || sectors * sector_size as u64 > metadata.len()
            || !(boot[21] == 0xf0 || boot[21] >= 0xf8)
        {
            return Err(invalid(
                "invalid or unsupported FAT32 partition boot sector",
            ));
        }
        let data_start = reserved + fats * fat_sectors;
        let data_sectors = sectors
            .checked_sub(data_start)
            .ok_or_else(|| invalid("FATs exceed volume"))?;
        let clusters = data_sectors / sectors_per_cluster;
        if !(65_525..u64::from(LAST_DATA_CLUSTER)).contains(&clusters)
            || clusters + 2 > fat_sectors * (sector_size as u64 / 4)
        {
            return Err(invalid("FAT32 cluster count or FAT capacity is invalid"));
        }
        let last_cluster = clusters as u32 + 1;
        let root_cluster = le32(&boot, 44);
        if !(2..=last_cluster).contains(&root_cluster) {
            return Err(invalid("invalid FAT32 root cluster"));
        }
        let (first_fat, fat_copies) = if flags & 0x80 == 0 {
            (0, fats)
        } else {
            let active = u64::from(flags & 0xf);
            if active >= fats {
                return Err(invalid("invalid active FAT index"));
            }
            (active, 1)
        };
        let reserved_sector = |offset| match u64::from(le16(&boot, offset)) {
            0 | 0xffff => Ok(None),
            sector if sector < reserved => Ok(Some(sector)),
            _ => Err(invalid("FSInfo or boot backup outside reserved area")),
        };
        let primary = reserved_sector(48)?;
        let backup_boot = reserved_sector(50)?;
        let backup_info = match (primary, backup_boot) {
            (Some(info), Some(backup)) if info != backup && info + backup < reserved => {
                Some(info + backup)
            }
            (Some(_), Some(_)) => return Err(invalid("invalid FAT32 backup FSInfo location")),
            _ => None,
        };
        let mut volume = Self {
            file,
            sector_size,
            sectors,
            sectors_per_cluster,
            data_start,
            fat_start: reserved,
            fat_sectors,
            first_fat,
            fat_copies,
            last_cluster,
            root_cluster,
            fsinfo: [primary, backup_info],
        };
        // Do not interpret even a hybrid GPT disk's LBA 0 as a partition BPB.
        let mut second_sector = [0; MAX_SECTOR];
        volume.read_sector(1, &mut second_sector)?;
        if &second_sector[..8] == b"EFI PART" {
            return Err(invalid("expected a FAT32 partition, not a GPT disk"));
        }
        let mut fat = FatReader::new();
        if fat.get(&mut volume, 0)? != (0x0fff_ff00 | u32::from(boot[21]))
            || fat.get(&mut volume, 1)? & 0x03ff_ffff != 0x03ff_ffff
        {
            return Err(invalid("invalid reserved FAT32 entries"));
        }
        Ok(volume)
    }

    fn seek_sector(&mut self, sector: u64) -> io::Result<()> {
        if sector >= self.sectors {
            return Err(invalid("sector outside FAT32 volume"));
        }
        self.file
            .seek(SeekFrom::Start(sector * self.sector_size as u64))?;
        Ok(())
    }

    fn read_sector(&mut self, sector: u64, data: &mut Sector) -> io::Result<()> {
        self.seek_sector(sector)?;
        read_full(&mut self.file, &mut data[..self.sector_size])
    }

    fn write_sector(&mut self, sector: u64, data: &Sector) -> io::Result<()> {
        self.seek_sector(sector)?;
        loop {
            match self.file.write(&data[..self.sector_size]) {
                Ok(n) if n == self.sector_size => return Ok(()),
                Ok(_) => {
                    return Err(io::Error::new(
                        ErrorKind::WriteZero,
                        "short ESP sector write",
                    ))
                }
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
    }

    fn valid_cluster(&self, cluster: u32) -> bool {
        (2..=self.last_cluster).contains(&cluster)
    }

    fn cluster_sector(&self, cluster: u32) -> u64 {
        self.data_start + u64::from(cluster - 2) * self.sectors_per_cluster
    }

    fn clusters_for(&self, bytes: u32) -> u32 {
        u64::from(bytes).div_ceil(self.sector_size as u64 * self.sectors_per_cluster) as u32
    }

    fn fat_location(&self, cluster: u32) -> (u64, usize) {
        let byte = u64::from(cluster) * 4;
        (
            byte / self.sector_size as u64,
            (byte % self.sector_size as u64) as usize,
        )
    }

    fn fat_sector(&self, copy: u64, offset: u64) -> u64 {
        self.fat_start + (self.first_fat + copy) * self.fat_sectors + offset
    }

    fn find_loader(&mut self, fat: &mut FatReader) -> io::Result<(Slot, Vec<FatLink>)> {
        // Check all live owners before allocating or reclaiming. Following only
        // EFI/BOOT would miss a cross-link from an unrelated file or directory.
        let mut owned = vec![0u8; self.last_cluster as usize / 8 + 1];
        let mut pending = vec![(self.root_cluster, None, Some(0usize))];
        let mut dir_chain = Vec::new();
        let mut old_chain = Vec::new();
        let mut slot = None;
        let mut data = [0; MAX_SECTOR];
        while let Some((start, parent, depth)) = pending.pop() {
            dir_chain.clear();
            self.claim_chain(start, fat, &mut owned, |cluster, _| dir_chain.push(cluster))?;
            let mut matched = false;
            'directory: for &cluster in &dir_chain {
                let first_sector = self.cluster_sector(cluster);
                for sector in first_sector..first_sector + self.sectors_per_cluster {
                    self.read_sector(sector, &mut data)?;
                    for (index, entry) in data[..self.sector_size].chunks_exact(32).enumerate() {
                        if entry[0] == 0 {
                            break 'directory;
                        }
                        let attr = entry[11];
                        if entry[0] == 0xe5 || attr == 0x0f {
                            continue;
                        }
                        if attr & 0xc0 != 0 || attr & 0x18 == 0x18 {
                            return Err(invalid("invalid FAT directory entry attributes"));
                        }
                        let first = (u32::from(le16(entry, 20)) << 16) | u32::from(le16(entry, 26));
                        let size = le32(entry, 28);
                        let directory = attr & 0x10 != 0;
                        if &entry[..11] == b".          " || &entry[..11] == b"..         " {
                            let dotdot = entry[1] == b'.';
                            let expected = if dotdot {
                                parent.unwrap_or(start)
                            } else {
                                start
                            };
                            let root_parent = dotdot && first == 0 && expected == self.root_cluster;
                            if !directory
                                || parent.is_none()
                                || size != 0
                                || (first != expected && !root_parent)
                            {
                                return Err(invalid("invalid FAT directory dot entry"));
                            }
                            continue;
                        }
                        if attr & 0x08 != 0 {
                            if first != 0 || size != 0 {
                                return Err(invalid("invalid FAT volume label"));
                            }
                            continue;
                        }
                        let on_path = depth.filter(|&i| entry[..11].eq_ignore_ascii_case(PATH[i]));
                        if let Some(i) = on_path {
                            if matched || directory != (i < PATH.len() - 1) {
                                return Err(invalid("duplicate or wrong-type EFI path entry"));
                            }
                            matched = true;
                        }
                        if directory {
                            if !self.valid_cluster(first) || size != 0 {
                                return Err(invalid("invalid FAT directory cluster or size"));
                            }
                            pending.push((first, Some(start), on_path.map(|i| i + 1)));
                        } else {
                            let needed = self.clusters_for(size);
                            let claimed = if first == 0 && needed == 0 {
                                0
                            } else {
                                self.claim_chain(first, fat, &mut owned, |cluster, next| {
                                    if on_path.is_some() {
                                        old_chain.push((cluster, next));
                                    }
                                })?
                            };
                            if claimed < needed
                                || (on_path.is_some() && (claimed != needed || size == 0))
                            {
                                return Err(invalid(
                                    "FAT file size does not match its cluster chain",
                                ));
                            }
                            if on_path.is_some() {
                                slot = Some(Slot {
                                    sector,
                                    offset: index * 32,
                                    entry: entry.try_into().unwrap(),
                                });
                            }
                        }
                    }
                }
            }
        }
        let slot = slot.ok_or_else(|| invalid("missing EFI/BOOT/BOOTX64.EFI short-name entry"))?;
        Ok((slot, old_chain))
    }

    fn claim_chain(
        &mut self,
        mut cluster: u32,
        fat: &mut FatReader,
        owned: &mut [u8],
        mut visit: impl FnMut(u32, u32),
    ) -> io::Result<u32> {
        let mut count = 0;
        loop {
            if !self.valid_cluster(cluster) {
                return Err(invalid("invalid cluster in FAT chain"));
            }
            let previous = &mut owned[cluster as usize / 8];
            let bit = 1u8 << (cluster % 8);
            if *previous & bit != 0 {
                return Err(invalid("cyclic or cross-linked FAT chain"));
            }
            *previous |= bit;
            let next = fat.get(self, cluster)?;
            visit(cluster, next);
            count += 1;
            cluster = next;
            if cluster >= EOC {
                return Ok(count);
            }
        }
    }

    fn find_free(&mut self, fat: &mut FatReader, count: u32) -> io::Result<Vec<u32>> {
        if count > self.last_cluster - 1 {
            return Err(io::Error::new(
                ErrorKind::StorageFull,
                "EFI exceeds FAT32 data area",
            ));
        }
        let mut chain = Vec::new();
        for cluster in 2..=self.last_cluster {
            if fat.get(self, cluster)? == 0 {
                chain.push(cluster);
                if chain.len() == count as usize {
                    return Ok(chain);
                }
            }
        }
        Err(io::Error::new(
            ErrorKind::StorageFull,
            "not enough free FAT32 clusters to stage EFI",
        ))
    }

    fn invalidate_fsinfo(&mut self) -> io::Result<()> {
        let mut data = [0; MAX_SECTOR];
        for sector in self.fsinfo.into_iter().flatten() {
            self.read_sector(sector, &mut data)?;
            if le32(&data, 0) == 0x4161_5252
                && le32(&data, 484) == 0x6141_7272
                && le32(&data, 508) == 0xaa55_0000
                && data[488..496] != [0xff; 8]
            {
                data[488..496].fill(0xff);
                self.write_sector(sector, &data)?;
            }
        }
        Ok(())
    }

    fn transfer(
        &mut self,
        source: &mut File,
        size: u32,
        chain: impl IntoIterator<Item = u32>,
        write: bool,
    ) -> io::Result<bool> {
        source.seek(SeekFrom::Start(0))?;
        let mut expected = [0; MAX_SECTOR];
        let mut actual = [0; MAX_SECTOR];
        let mut left = u64::from(size);
        for cluster in chain {
            let first_sector = self.cluster_sector(cluster);
            for sector in first_sector..first_sector + self.sectors_per_cluster {
                let n = left.min(self.sector_size as u64) as usize;
                if n == 0 && !write {
                    break;
                }
                left -= n as u64;
                source.read_exact(&mut expected[..n])?;
                if write {
                    expected[n..self.sector_size].fill(0);
                    self.write_sector(sector, &expected)?;
                } else {
                    self.read_sector(sector, &mut actual)?;
                    if expected[..n] != actual[..n] {
                        return Ok(false);
                    }
                }
            }
        }
        let mut extra = [0];
        if left != 0 || source.read(&mut extra)? != 0 {
            return Err(invalid("EFI source size changed during installation"));
        }
        Ok(true)
    }

    fn verify_chain(&mut self, chain: &[u32]) -> io::Result<()> {
        let mut fat = FatReader::new();
        for (i, &cluster) in chain.iter().enumerate() {
            if fat.get(self, cluster)? != next_link(chain, i) {
                return Err(invalid("replacement FAT chain failed readback"));
            }
        }
        Ok(())
    }

    // Edits are sorted by cluster: write each affected sector once per FAT copy.
    // Each edit yields (cluster, expected FAT value, replacement FAT value).
    fn change_fat(
        &mut self,
        count: usize,
        edit: impl Fn(usize) -> (u32, u32, u32),
    ) -> io::Result<()> {
        let mut data = [0; MAX_SECTOR];
        let mut i = 0;
        while i < count {
            let (offset, _) = self.fat_location(edit(i).0);
            let mut end = i + 1;
            while end < count && self.fat_location(edit(end).0).0 == offset {
                end += 1;
            }
            for copy in 0..self.fat_copies {
                let sector = self.fat_sector(copy, offset);
                self.read_sector(sector, &mut data)?;
                for j in i..end {
                    let (cluster, expected, value) = edit(j);
                    let (_, at) = self.fat_location(cluster);
                    let old = le32(&data, at);
                    if old & FAT_MASK != expected {
                        return Err(invalid("FAT entry changed during installation"));
                    }
                    data[at..at + 4].copy_from_slice(&((old & !FAT_MASK) | value).to_le_bytes());
                }
                self.write_sector(sector, &data)?;
            }
            i = end;
        }
        Ok(())
    }
}

struct Slot {
    sector: u64,
    offset: usize,
    entry: [u8; 32],
}

struct FatReader {
    offset: Option<u64>,
    data: Sector,
    mirror: Sector,
}

impl FatReader {
    fn new() -> Self {
        Self {
            offset: None,
            data: [0; MAX_SECTOR],
            mirror: [0; MAX_SECTOR],
        }
    }

    fn get(&mut self, volume: &mut Volume, cluster: u32) -> io::Result<u32> {
        let (offset, at) = volume.fat_location(cluster);
        if self.offset != Some(offset) {
            let sector = volume.fat_sector(0, offset);
            volume.read_sector(sector, &mut self.data)?;
            if volume.fat_copies == 2 {
                let sector = volume.fat_sector(1, offset);
                volume.read_sector(sector, &mut self.mirror)?;
                let last_byte = (u64::from(volume.last_cluster) + 1) * 4;
                let end = (last_byte - offset * volume.sector_size as u64)
                    .min(volume.sector_size as u64) as usize;
                for byte in (0..end).step_by(4) {
                    if (le32(&self.data, byte) ^ le32(&self.mirror, byte)) & FAT_MASK != 0 {
                        return Err(invalid("FAT32 copies disagree"));
                    }
                }
            }
            self.offset = Some(offset);
        }
        Ok(le32(&self.data, at) & FAT_MASK)
    }
}

fn read_full(file: &mut File, data: &mut [u8]) -> io::Result<()> {
    loop {
        match file.read(data) {
            Ok(n) if n == data.len() => return Ok(()),
            Ok(_) => {
                return Err(io::Error::new(
                    ErrorKind::UnexpectedEof,
                    "short ESP sector read",
                ))
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
}
