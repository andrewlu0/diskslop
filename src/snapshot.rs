use super::*;
use std::io::{BufReader, BufWriter, Read, Write};
use std::os::unix::fs::OpenOptionsExt;

const MAGIC: &[u8; 8] = b"DSINDEX1";
const RECORD: usize = 44;

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "Invalid scan cache")
}

fn u32_from(n: usize) -> io::Result<u32> {
    n.try_into().map_err(|_| invalid())
}

fn take<const N: usize>(data: &mut &[u8]) -> io::Result<[u8; N]> {
    let (value, rest) = data.split_at_checked(N).ok_or_else(invalid)?;
    *data = rest;
    Ok(value.try_into().unwrap())
}

fn number<const N: usize>(r: &mut impl Read) -> io::Result<[u8; N]> {
    let mut bytes = [0; N];
    r.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn open_cache(path: &Path) -> io::Result<impl Read> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        return Err(invalid());
    }
    let mut decoder = zstd::stream::Decoder::new(file)?;
    decoder.window_log_max(24)?;
    Ok(BufReader::with_capacity(128 * 1024, decoder))
}

fn checkpoint_header(r: &mut impl Read, journal: &[u8; 16], inode: u64) -> io::Result<u64> {
    if &number::<8>(r)? != MAGIC || &number::<16>(r)? != journal {
        return Err(invalid());
    }
    let cursor = u64::from_le_bytes(number(r)?);
    if u64::from_le_bytes(number(r)?) != inode {
        return Err(invalid());
    }
    Ok(cursor)
}

pub(super) fn save(
    scan: &Inventory,
    path: &Path,
    journal: &[u8; 16],
    checkpoint: u64,
    replacing_inode: u64,
    progress: &Progress,
) -> io::Result<()> {
    if scan.provisional {
        return Err(invalid());
    }
    let parent = path.parent().ok_or_else(invalid)?;
    let temp = tempfile::NamedTempFile::new_in(parent)?;
    let mut stream = zstd::stream::Encoder::new(BufWriter::new(temp.as_file()), 1)?;
    stream.include_checksum(true)?;
    stream.write_all(MAGIC)?;
    stream.write_all(journal)?;
    stream.write_all(&checkpoint.to_le_bytes())?;
    stream.write_all(&scan.folders[0].inode.to_le_bytes())?;
    stream.write_all(&u32_from(scan.folders.len())?.to_le_bytes())?;
    let mut block = Vec::new();
    for (id, f) in scan.folders.iter().enumerate() {
        progress.check()?;
        let order = &scan.order[id];
        if order.len() != f.entries.len() {
            return Err(invalid());
        }
        let dates = f.dates.as_ref().ok_or_else(invalid)?;
        block.clear();
        block.extend_from_slice(&f.inode.to_le_bytes());
        block.extend_from_slice(&f.own_bytes.to_le_bytes());
        block.extend_from_slice(&f.issues.to_le_bytes());
        block.extend_from_slice(&f.boundaries.to_le_bytes());
        block.extend_from_slice(&u32_from(f.entries.len())?.to_le_bytes());
        for (slot, entry) in f.entries.iter().enumerate() {
            let bytes = if entry.flags & LINKED == 0 {
                entry.bytes
            } else {
                scan.groups
                    .get(&entry.inode)
                    .map_or(entry.bytes, |g| g.bytes)
            };
            block.extend_from_slice(&entry.inode.to_le_bytes());
            block.extend_from_slice(&bytes.to_le_bytes());
            block.extend_from_slice(&entry.finder_type.to_le_bytes());
            block.extend_from_slice(&entry.child.to_le_bytes());
            for date in dates[slot].0 {
                block.extend_from_slice(&date.to_le_bytes());
            }
            block.extend_from_slice(&entry.len.to_le_bytes());
            block.push(entry.kind as u8);
            block.push(entry.flags);
            block.extend_from_slice(&order[slot].to_le_bytes());
            block.extend_from_slice(f.name(slot));
        }
        stream.write_all(&u32_from(block.len())?.to_le_bytes())?;
        stream.write_all(&block)?;
    }
    stream.write_all(MAGIC)?;
    stream.finish()?.flush()?;
    progress.check()?;
    let directory = fs::File::open(parent)?;
    directory.lock()?;
    let published = open_cache(path)
        .and_then(|mut r| checkpoint_header(&mut r, journal, scan.folders[0].inode));
    let repairing = replacing_inode != 0
        && fs::symlink_metadata(path).is_ok_and(|m| m.ino() == replacing_inode);
    if !repairing && published.is_ok_and(|event| event > checkpoint) {
        return Ok(());
    }
    temp.persist(path)?;
    Ok(())
}

fn folder(mut data: &[u8], id: usize, count: usize) -> io::Result<(Folder, Arc<[u32]>)> {
    let inode = u64::from_le_bytes(take(&mut data)?);
    let own_bytes = u64::from_le_bytes(take(&mut data)?);
    let issues = u64::from_le_bytes(take(&mut data)?);
    let boundaries = u64::from_le_bytes(take(&mut data)?);
    let n = u32::from_le_bytes(take(&mut data)?) as usize;
    if n > data.len() / RECORD {
        return Err(invalid());
    }
    let mut f = Folder {
        inode,
        total: own_bytes,
        own_bytes,
        issues,
        boundaries,
        entries: SharedVec::Building(Vec::with_capacity(n)),
        names: SharedVec::Building(Vec::with_capacity(data.len() - n * RECORD)),
        dates: Some(SharedVec::Building(Vec::with_capacity(n))),
        ..Folder::default()
    };
    let mut order = Vec::with_capacity(n);
    let mut used = vec![false; n];
    for _ in 0..n {
        let inode = u64::from_le_bytes(take(&mut data)?);
        let bytes = u64::from_le_bytes(take(&mut data)?);
        let finder_type = u32::from_le_bytes(take(&mut data)?);
        let child = u32::from_le_bytes(take(&mut data)?);
        let mut dates = [0; 3];
        for date in &mut dates {
            *date = i32::from_le_bytes(take(&mut data)?);
        }
        let len = u16::from_le_bytes(take(&mut data)?);
        let [kind, flags] = take(&mut data)?;
        let kind = match kind {
            0 => EntryKind::File,
            1 => EntryKind::Directory,
            2 => EntryKind::Link,
            3 => EntryKind::Other,
            _ => return Err(invalid()),
        };
        let slot = u32::from_le_bytes(take(&mut data)?);
        let marked = used.get_mut(slot as usize).ok_or_else(invalid)?;
        if *marked || flags & !(LINKED | EXECUTABLE | FINDER_BUNDLE) != 0 {
            return Err(invalid());
        }
        *marked = true;
        if kind == EntryKind::Directory {
            if child as usize <= id || child as usize >= count || flags & LINKED != 0 {
                return Err(invalid());
            }
        } else if child != NONE {
            return Err(invalid());
        }
        let (name, rest) = data.split_at_checked(len as usize).ok_or_else(invalid)?;
        if name.is_empty()
            || matches!(name, b"." | b"..")
            || name.contains(&b'/')
            || name.contains(&0)
        {
            return Err(invalid());
        }
        data = rest;
        f.entries.push(Entry {
            inode,
            bytes,
            finder_type,
            child,
            start: f.names.len(),
            len,
            kind,
            flags,
        });
        f.names.extend_from_slice(name);
        f.dates.as_mut().unwrap().push(bulk::FileDates(dates));
        order.push(slot);
    }
    if !data.is_empty() {
        return Err(invalid());
    }
    Ok((f, order.into()))
}

pub(super) fn load(
    path: &Path,
    root: &Path,
    journal: &[u8; 16],
    progress: &Progress,
) -> io::Result<(Inventory, u64)> {
    let root = fs::canonicalize(root)?;
    let meta = fs::metadata(&root)?;
    let mut r = open_cache(path)?;
    let checkpoint = checkpoint_header(&mut r, journal, meta.ino())?;
    let count = u32::from_le_bytes(number(&mut r)?) as usize;
    if count == 0 {
        return Err(invalid());
    }
    let mut folders = Vec::new();
    let mut orders = Vec::new();
    let mut block = Vec::new();
    for id in 0..count {
        progress.check()?;
        let size = u32::from_le_bytes(number(&mut r)?) as usize;
        block.clear();
        (&mut r).take(size as u64).read_to_end(&mut block)?;
        if block.len() != size {
            return Err(invalid());
        }
        let (folder, order) = folder(&block, id, count)?;
        folders.push(folder);
        orders.push(order);
    }
    if &number::<8>(&mut r)? != MAGIC || r.read(&mut [0])? != 0 || folders[0].inode != meta.ino() {
        return Err(invalid());
    }
    for id in 0..count {
        let (previous, children) = folders.split_at_mut(id + 1);
        let f = &previous[id];
        if id != 0 && f.parent.is_none() {
            return Err(invalid());
        }
        for (slot, e) in f
            .entries
            .iter()
            .enumerate()
            .filter(|(_, e)| e.child != NONE)
        {
            let child = &mut children[e.child as usize - id - 1];
            if child.inode != e.inode || child.parent.is_some() {
                return Err(invalid());
            }
            child.parent = Some(Key {
                folder: id as u32,
                slot: slot as u32,
            });
        }
    }
    let mut scan = Inventory {
        root,
        device: meta.dev(),
        folders: folders.into(),
        order: orders.into(),
        revision: Arc::new(()),
        scan_id: None,
        provisional: false,
        delta: None,
        rebuilt_from: None,
        groups: Arc::default(),
        owners: Arc::default(),
        dirty_order: Vec::new(),
        protected: Vec::new(),
        issues: 0,
        boundaries: 0,
    };
    scan.finish(progress)?;
    scan.protected = trash::protected_folders(&scan);
    scan.folders.iter_mut().for_each(Folder::freeze);
    Ok((scan, checkpoint))
}
