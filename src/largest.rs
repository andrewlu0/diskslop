use super::*;
use crate::bridge::Model;
use std::collections::{BTreeSet, BinaryHeap};
use std::ffi::CString;
use std::ptr;

const LIMIT: usize = 100;

#[derive(Default)]
pub(super) struct LiveRanking {
    pub(super) enabled: AtomicBool,
    cutoff: AtomicU64,
    revision: AtomicU64,
    files: Mutex<BTreeSet<(u64, PathBuf, u64)>>,
}

impl LiveRanking {
    pub(super) fn observe(&self, folder: &Folder, start: usize, path: &Path) {
        if !self.enabled.load(Ordering::Relaxed) {
            return;
        }
        let cutoff = self.cutoff.load(Ordering::Relaxed);
        let mut candidates = folder.entries[start..]
            .iter()
            .enumerate()
            .filter(|(_, e)| e.kind == EntryKind::File && e.bytes >= cutoff)
            .peekable();
        if candidates.peek().is_none() {
            return;
        }
        let mut files = self.files.lock().unwrap();
        let mut changed = false;
        for (i, e) in candidates {
            if files.len() == LIMIT && files.first().is_some_and(|first| e.bytes <= first.0) {
                continue;
            }
            let inode = if e.flags & LINKED != 0 { e.inode } else { 0 };
            if inode != 0 && files.iter().any(|f| f.2 == inode) {
                continue;
            }
            let name = path.join(OsStr::from_bytes(folder.name(start + i)));
            if files.insert((e.bytes, name, inode)) {
                changed = true;
                if files.len() > LIMIT {
                    files.pop_first();
                }
            }
        }
        if files.len() == LIMIT {
            self.cutoff.store(
                files.first().unwrap().0.saturating_add(1),
                Ordering::Relaxed,
            );
        }
        if changed {
            self.revision.fetch_add(1, Ordering::Release);
        }
    }
}

struct RankedFile {
    bytes: u64,
    path: CString,
    key: Key,
}
struct Ranking(Vec<RankedFile>);
impl RankedFile {
    fn new(bytes: u64, path: &Path, key: Key) -> Self {
        Self {
            bytes,
            path: CString::new(path.as_os_str().as_bytes()).unwrap(),
            key,
        }
    }
}
#[unsafe(no_mangle)]
extern "C" fn dt_live_largest(p: &Progress, since: &mut u64) -> *mut Ranking {
    let r = &p.largest;
    if r.revision.load(Ordering::Acquire) == *since {
        return ptr::null_mut();
    }
    let files = r.files.lock().unwrap();
    *since = r.revision.load(Ordering::Relaxed);
    let rows = files
        .iter()
        .rev()
        .map(|(bytes, path, _)| {
            RankedFile::new(
                *bytes,
                path,
                Key {
                    folder: NONE,
                    slot: NONE,
                },
            )
        })
        .collect();
    Box::into_raw(Box::new(Ranking(rows)))
}

#[unsafe(no_mangle)]
extern "C" fn dt_largest_files(model: &Model, root: u32) -> *mut Ranking {
    let scan = model.scan.read().unwrap();
    let mut pending = BinaryHeap::new();
    let queue = |pending: &mut BinaryHeap<_>, folder: u32, index: usize| {
        if let Some(&slot) = scan.order[folder as usize].get(index) {
            pending.push((scan.size(Key { folder, slot }), folder, index));
        }
    };
    queue(&mut pending, root, 0);
    let mut rows = Vec::with_capacity(LIMIT);
    while let Some((bytes, folder, index)) = pending.pop() {
        let key = Key {
            folder,
            slot: scan.order[folder as usize][index],
        };
        let e = scan.entry(key);
        if e.child != NONE {
            queue(&mut pending, e.child, 0);
        } else if e.kind == EntryKind::File
            && (e.flags & LINKED == 0 || scan.groups.get(&e.inode).is_none_or(|g| g.owner == key))
        {
            rows.push(RankedFile::new(bytes, &scan.path(key), key));
            if rows.len() == LIMIT {
                break;
            }
        }
        queue(&mut pending, folder, index + 1);
    }
    rows.sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.path.cmp(&b.path)));
    Box::into_raw(Box::new(Ranking(rows)))
}

#[unsafe(no_mangle)]
extern "C" fn dt_ranked_count(r: &Ranking) -> usize {
    r.0.len()
}
#[unsafe(no_mangle)]
extern "C" fn dt_ranked_file(
    r: &Ranking,
    index: usize,
    bytes: &mut u64,
    key: &mut Key,
) -> *const c_char {
    let Some(file) = r.0.get(index) else {
        return ptr::null();
    };
    *bytes = file.bytes;
    *key = file.key;
    file.path.as_ptr()
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_ranked_free(r: *mut Ranking) {
    unsafe {
        drop(Box::from_raw(r));
    }
}
