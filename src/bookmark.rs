use super::*;

struct Choice {
    slot: u32,
    inode: u64,
    name: Box<[u8]>,
}

struct Parent {
    folder: u32,
    inode: u64,
    path: PathBuf,
    items: Vec<Choice>,
}

struct Bookmark {
    parents: Vec<Parent>,
    selects_root: bool,
    device: u64,
    root: u64,
}

#[repr(C)]
#[derive(Default)]
struct Identity {
    device: u64,
    inode: u64,
}

#[unsafe(no_mangle)]
extern "C" fn dt_directory_identity(m: &Model, folder: u32) -> Identity {
    let scan = m.scan.read().unwrap();
    scan.folders
        .get(folder as usize)
        .map_or_else(Identity::default, |f| Identity {
            device: scan.device,
            inode: f.inode,
        })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn dt_bookmark_new(m: &Model, keys: *const u64, count: usize) -> *mut Bookmark {
    let scan = m.scan.read().unwrap();
    let mut parents = HashMap::new();
    let mut selects_root = false;
    if !keys.is_null() {
        for &raw in unsafe { std::slice::from_raw_parts(keys, count) } {
            let key = Key {
                folder: (raw >> 32) as u32,
                slot: raw as u32,
            };
            if key == SCAN_ROOT {
                selects_root = true;
                continue;
            }
            if !scan.live(key) {
                continue;
            }
            let f = &scan.folders[key.folder as usize];
            let parent = parents.entry(key.folder).or_insert_with(|| Parent {
                folder: key.folder,
                inode: f.inode,
                items: Vec::new(),
                path: f.parent.map_or_else(|| scan.root.clone(), |k| scan.path(k)),
            });
            parent.items.push(Choice {
                slot: key.slot,
                inode: scan.entry(key).inode,
                name: scan.name(key).into(),
            });
        }
    }
    Box::into_raw(Box::new(Bookmark {
        parents: parents.into_values().collect(),
        selects_root,
        device: scan.device,
        root: scan.folders[0].inode,
    }))
}

#[unsafe(no_mangle)]
unsafe extern "C" fn dt_bookmark_free(p: *mut Bookmark) {
    unsafe {
        drop(Box::from_raw(p));
    }
}

fn folder_at(scan: &Inventory, path: &Path) -> Option<u32> {
    let mut id = 0;
    for component in path.strip_prefix(&scan.root).ok()?.iter() {
        let f = &scan.folders[id as usize];
        let (_, entry) = f.named_entry(component.as_bytes())?;
        if entry.child == NONE {
            return None;
        }
        id = entry.child;
    }
    Some(id)
}

#[unsafe(no_mangle)]
unsafe extern "C" fn dt_bookmark_resolve(
    m: &Model,
    b: &Bookmark,
    same_index: bool,
    out: *mut u64,
    capacity: usize,
) -> usize {
    let scan = m.scan.read().unwrap();
    if out.is_null() || (scan.device, scan.folders[0].inode) != (b.device, b.root) {
        return 0;
    }
    let buffer = unsafe { std::slice::from_raw_parts_mut(out, capacity) };
    let mut n = 0;
    if b.selects_root
        && let Some(first) = buffer.first_mut()
    {
        *first = u64::from(SCAN_ROOT.slot);
        n = 1;
    }
    for p in &b.parents {
        let dir = if same_index {
            Some(p.folder)
        } else {
            folder_at(&scan, &p.path)
        };
        let Some(dir) = dir else { continue };
        let f = &scan.folders[dir as usize];
        if f.inode != p.inode || !scan.live_folder(dir) {
            continue;
        }
        let mut missed = HashMap::new();
        let mut append = |slot: u32| {
            if let Some(cell) = buffer.get_mut(n) {
                *cell = u64::from(dir) << 32 | u64::from(slot);
                n += 1;
            }
        };
        for item in &p.items {
            if f.entries.get(item.slot as usize).is_some_and(|e| {
                e.flags & REMOVED == 0
                    && e.inode == item.inode
                    && f.name(item.slot as usize) == item.name.as_ref()
            }) {
                append(item.slot);
            } else if !same_index {
                missed.insert(item.name.as_ref(), item.inode);
            }
        }
        if !missed.is_empty() {
            for (i, e) in f.entries.iter().enumerate() {
                if e.flags & REMOVED == 0 && missed.get(f.name(i)) == Some(&e.inode) {
                    append(i as u32);
                }
            }
        }
    }
    n
}
