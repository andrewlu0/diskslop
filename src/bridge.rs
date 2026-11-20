use super::*;
use std::ffi::CString;
use std::ptr;
use std::sync::RwLock;
#[path = "bookmark.rs"]
mod bookmark;
#[path = "treemap.rs"]
mod treemap;

pub(super) struct Model {
    pub(super) scan: RwLock<Inventory>,
    estimated_bytes: usize,
    moves: Mutex<()>,
}
struct Listing(Vec<Row>);
const SCAN_ROOT: Key = Key {
    folder: 0,
    slot: NONE,
};

#[repr(C)]
struct Row {
    name: *const u8,
    bytes: u64,
    name_len: usize,
    slot: u32,
    child: u32,
    kind: u8,
    partial: bool,
}

#[repr(C)]
#[derive(Default)]
struct Summary {
    bytes: u64,
    entries: u64,
    issues: u64,
    boundaries: u64,
}

fn string(s: &[u8]) -> *mut c_char {
    CString::new(s).map_or(ptr::null_mut(), CString::into_raw)
}
fn error(out: *mut *mut c_char, e: io::Error) {
    if !out.is_null() {
        unsafe {
            *out = string(e.to_string().as_bytes());
        }
    }
}

#[unsafe(no_mangle)]
extern "C" fn dt_progress_new() -> *mut Progress {
    Box::into_raw(Box::default())
}
#[unsafe(no_mangle)]
extern "C" fn dt_progress_count(p: &Progress) -> u64 {
    p.count()
}
#[unsafe(no_mangle)]
extern "C" fn dt_enable_scan_workspace(p: &Progress) {
    p.workspace.enable();
}
#[unsafe(no_mangle)]
extern "C" fn dt_scan_workspace_next(p: &Progress) -> *mut Model {
    let Some(scan) = p.workspace.next(p) else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(Model {
        scan: RwLock::new(scan),
        estimated_bytes: 0,
        moves: Mutex::new(()),
    }))
}
#[unsafe(no_mangle)]
extern "C" fn dt_close_scan_workspace(p: &Progress) {
    p.workspace.close();
}
#[unsafe(no_mangle)]
extern "C" fn dt_cancel(p: &Progress) {
    p.cancel();
}
#[unsafe(no_mangle)]
extern "C" fn dt_is_cancelled(p: &Progress) -> bool {
    p.cancelled.load(Ordering::Relaxed)
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_progress_free(p: *mut Progress) {
    unsafe {
        drop(Box::from_raw(p));
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn dt_scan(
    path: *const c_char,
    p: &Progress,
    err: *mut *mut c_char,
) -> *mut Model {
    unsafe { dt_scan_with_preview(path, p, true, err) }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_scan_with_preview(
    path: *const c_char,
    p: &Progress,
    preview: bool,
    err: *mut *mut c_char,
) -> *mut Model {
    let path = Path::new(OsStr::from_bytes(
        unsafe { CStr::from_ptr(path) }.to_bytes(),
    ));
    p.largest.enabled.store(preview, Ordering::Relaxed);
    wrap(Inventory::build(path, default_threads(), p, true), err)
}

#[unsafe(no_mangle)]
unsafe extern "C" fn dt_snapshot_save(
    m: &Model,
    file: *const c_char,
    journal: &[u8; 16],
    event: u64,
    replacing_inode: u64,
    p: &Progress,
) -> bool {
    let file = Path::new(OsStr::from_bytes(
        unsafe { CStr::from_ptr(file) }.to_bytes(),
    ));
    let scan = m.scan.read().unwrap().clone();
    snapshot::save(&scan, file, journal, event, replacing_inode, p).is_ok()
}

#[unsafe(no_mangle)]
unsafe extern "C" fn dt_snapshot_load(
    file: *const c_char,
    root: *const c_char,
    journal: &[u8; 16],
    event: &mut u64,
    p: &Progress,
) -> *mut Model {
    let path = |ptr| Path::new(OsStr::from_bytes(unsafe { CStr::from_ptr(ptr) }.to_bytes()));
    let Ok((scan, checkpoint)) = snapshot::load(path(file), path(root), journal, p) else {
        return ptr::null_mut();
    };
    *event = checkpoint;
    wrap(Ok(scan), ptr::null_mut())
}

#[unsafe(no_mangle)]
extern "C" fn dt_same_inventory(old: &Model, next: &Model, progress: &Progress) -> bool {
    let old = old.scan.read().unwrap();
    let next = next.scan.read().unwrap();
    if old.root != next.root || old.device != next.device || old.folders.len() != next.folders.len()
    {
        return false;
    }
    let mut pending = vec![(0, 0)];
    while let Some((a, b)) = pending.pop() {
        let a = &old.folders[a];
        let b = &next.folders[b];
        if progress.cancelled.load(Ordering::Relaxed)
            || a.inode != b.inode
            || a.own_bytes != b.own_bytes
            || a.total != b.total
            || a.issues != b.issues
            || a.boundaries != b.boundaries
            || a.names.as_slice() != b.names.as_slice()
            || a.entries.len() != b.entries.len()
            || a.dates.as_deref() != b.dates.as_deref()
        {
            return false;
        }
        for (before, after) in a.entries.iter().zip(b.entries.iter()) {
            if (before.child == NONE) != (after.child == NONE)
                || *before
                    != (Entry {
                        child: before.child,
                        ..after.clone()
                    })
            {
                return false;
            }
            if before.child != NONE {
                pending.push((before.child as usize, after.child as usize));
            }
        }
    }
    true
}
fn wrap(result: io::Result<Inventory>, err: *mut *mut c_char) -> *mut Model {
    wrap_cached(result, None, err)
}
fn wrap_cached(
    result: io::Result<Inventory>,
    prior: Option<(&Inventory, usize)>,
    err: *mut *mut c_char,
) -> *mut Model {
    match result {
        Ok(scan) => {
            let folder_bytes = |scan: &Inventory, id: usize| {
                let f = &scan.folders[id];
                std::mem::size_of::<Folder>()
                    + f.entries.capacity() * std::mem::size_of::<Entry>()
                    + f.names.capacity()
                    + f.dates
                        .as_ref()
                        .map_or(0, |d| d.capacity() * std::mem::size_of::<bulk::FileDates>())
                    + scan.order.get(id).map_or(0, |order| {
                        std::mem::size_of_val(order.as_ref()) + std::mem::size_of::<Arc<[u32]>>()
                    })
            };
            let estimated_bytes = if let (Some((old, bytes)), Some((base, dirty))) =
                (prior, &scan.delta)
                && Arc::ptr_eq(base, &old.revision)
            {
                dirty.iter().fold(bytes, |total, &id| {
                    total.saturating_sub(folder_bytes(old, id as usize))
                        + folder_bytes(&scan, id as usize)
                })
            } else {
                (0..scan.folders.len())
                    .map(|id| folder_bytes(&scan, id))
                    .sum::<usize>()
                    + scan
                        .groups
                        .values()
                        .map(|g| g.members.capacity() * std::mem::size_of::<Key>() + 128)
                        .sum::<usize>()
            };
            Box::into_raw(Box::new(Model {
                estimated_bytes,
                scan: RwLock::new(scan),
                moves: Mutex::new(()),
            }))
        }
        Err(e) => {
            error(err, e);
            ptr::null_mut()
        }
    }
}
#[unsafe(no_mangle)]
extern "C" fn dt_memory_bytes(m: &Model) -> u64 {
    m.estimated_bytes as u64
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_outline_order_unchanged(
    old: &Model,
    next: &Model,
    folders: *const u32,
    count: usize,
) -> bool {
    let next = next.scan.read().unwrap();
    let Some((base, _)) = &next.delta else {
        return false;
    };
    let old = old.scan.read().unwrap();
    if !Arc::ptr_eq(base, &old.revision) || folders.is_null() {
        return false;
    }
    for &id in unsafe { std::slice::from_raw_parts(folders, count) } {
        let id = id as usize;
        let (Some(a), Some(b)) = (old.folders.get(id), next.folders.get(id)) else {
            return false;
        };
        if a.inode != b.inode || a.parent != b.parent {
            return false;
        }
        let (before, after) = (&old.order[id], &next.order[id]);
        if !Arc::ptr_eq(before, after) && before != after {
            return false;
        }
        if a.entries.as_ptr() != b.entries.as_ptr()
            && (a.names.as_slice() != b.names.as_slice()
                || a.entries.len() != b.entries.len()
                || a.entries.iter().zip(b.entries.iter()).any(|(a, b)| {
                    a.inode != b.inode
                        || a.child != b.child
                        || a.start != b.start
                        || a.len != b.len
                        || a.kind != b.kind
                        || a.flags != b.flags
                        || a.finder_type != b.finder_type
                }))
        {
            return false;
        }
    }
    true
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_model_free(p: *mut Model) {
    unsafe {
        drop(Box::from_raw(p));
    }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_refresh(
    m: &Model,
    keys: *const Key,
    count: usize,
    p: &Progress,
    err: *mut *mut c_char,
) -> *mut Model {
    if count == 0 || keys.is_null() {
        error(err, io::Error::other("Select an item to refresh."));
        return ptr::null_mut();
    }
    let keys = unsafe { std::slice::from_raw_parts(keys, count) };
    wrap(m.scan.read().unwrap().refreshed(keys, p), err)
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_route(m: &Model, path: *const c_char) -> *mut Listing {
    let scan = m.scan.read().unwrap();
    let path = Path::new(OsStr::from_bytes(
        unsafe { CStr::from_ptr(path) }.to_bytes(),
    ));
    let resolved;
    let relative = match path.strip_prefix(&scan.root) {
        Ok(relative) => relative,
        Err(_) => {
            resolved = path
                .parent()
                .and_then(|p| fs::canonicalize(p).ok())
                .zip(path.file_name())
                .map(|(dir, name)| dir.join(name));
            match resolved
                .as_deref()
                .and_then(|p| p.strip_prefix(&scan.root).ok())
            {
                Some(relative) => relative,
                None if fs::canonicalize(path).ok().as_deref() == Some(scan.root.as_path()) => {
                    Path::new("")
                }
                None => return ptr::null_mut(),
            }
        }
    };
    let mut dir = 0;
    let mut rows = Vec::new();
    for component in relative.iter() {
        let Some(f) = scan.folders.get(dir as usize) else {
            return ptr::null_mut();
        };
        let Some((slot, _)) = f.named_entry(component.as_bytes()) else {
            return ptr::null_mut();
        };
        let row = make_row(&scan, dir, slot as u32);
        dir = row.child;
        rows.push(row);
    }
    Box::into_raw(Box::new(Listing(rows)))
}
#[unsafe(no_mangle)]
extern "C" fn dt_key_route(m: &Model, root: u32, key: Key) -> *mut Listing {
    if key == SCAN_ROOT && root == 0 {
        return Box::into_raw(Box::new(Listing(Vec::new())));
    }
    let scan = m.scan.read().unwrap();
    if !scan.live(key) {
        return ptr::null_mut();
    }
    let mut rows = Vec::new();
    let mut current = key;
    loop {
        rows.push(make_row(&scan, current.folder, current.slot));
        if current.folder == root {
            break;
        }
        let Some(parent) = scan.folders[current.folder as usize].parent else {
            return ptr::null_mut();
        };
        current = parent;
    }
    rows.reverse();
    Box::into_raw(Box::new(Listing(rows)))
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_refresh_paths(
    m: &Model,
    paths: *const u8,
    length: usize,
    p: &Progress,
    err: *mut *mut c_char,
) -> *mut Model {
    if length == 0 || paths.is_null() {
        error(err, io::Error::other("Event paths are unavailable."));
        return ptr::null_mut();
    }
    let paths = unsafe { std::slice::from_raw_parts(paths, length) };
    wrap(m.scan.read().unwrap().refresh_paths(paths, p), err)
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_refresh_changes(
    m: &Model,
    shallow: *const u8,
    shallow_len: usize,
    recursive: *const u8,
    recursive_len: usize,
    p: &Progress,
    err: *mut *mut c_char,
) -> *mut Model {
    unsafe {
        dt_refresh_changed(
            m,
            shallow,
            shallow_len,
            recursive,
            recursive_len,
            p,
            ptr::null_mut(),
            err,
        )
    }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_refresh_changed(
    m: &Model,
    shallow: *const u8,
    shallow_len: usize,
    recursive: *const u8,
    recursive_len: usize,
    p: &Progress,
    unchanged: *mut bool,
    err: *mut *mut c_char,
) -> *mut Model {
    unsafe {
        dt_revalidate_changes(
            m,
            shallow,
            shallow_len,
            recursive,
            recursive_len,
            false,
            p,
            unchanged,
            err,
        )
    }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_revalidate_changes(
    m: &Model,
    shallow: *const u8,
    shallow_len: usize,
    recursive: *const u8,
    recursive_len: usize,
    retry_issues: bool,
    p: &Progress,
    unchanged: *mut bool,
    err: *mut *mut c_char,
) -> *mut Model {
    let slice = |data, len| {
        if len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(data, len) }
        }
    };
    let scan = m.scan.read().unwrap();
    let refreshed = scan.refresh_changes(
        slice(shallow, shallow_len),
        slice(recursive, recursive_len),
        retry_issues,
        p,
    );
    if let Some(unchanged) = unsafe { unchanged.as_mut() } {
        *unchanged = matches!(refreshed, Ok(Cow::Borrowed(_)));
        if *unchanged {
            return ptr::null_mut();
        }
    }
    wrap_cached(
        refreshed.map(Cow::into_owned),
        Some((&scan, m.estimated_bytes)),
        err,
    )
}
#[unsafe(no_mangle)]
extern "C" fn dt_summary(m: &Model, folder: u32) -> Summary {
    let scan = m.scan.read().unwrap();
    scan.folders
        .get(folder as usize)
        .map_or_else(Summary::default, |f| Summary {
            bytes: f.total,
            entries: f.count,
            issues: scan.issues,
            boundaries: scan.boundaries,
        })
}
#[unsafe(no_mangle)]
extern "C" fn dt_list(m: &Model, folder: u32, limit: usize) -> *mut Listing {
    let scan = m.scan.read().unwrap();
    let rows = scan
        .largest_children(folder, limit)
        .into_iter()
        .map(|slot| make_row(&scan, folder, slot))
        .collect();
    Box::into_raw(Box::new(Listing(rows)))
}
fn make_row(scan: &Inventory, folder: u32, slot: u32) -> Row {
    let key = Key { folder, slot };
    let e = scan.entry(key);
    let name = scan.name(key);
    Row {
        name: name.as_ptr(),
        name_len: name.len(),
        bytes: scan.size(key),
        slot,
        child: e.child,
        kind: e.kind as u8,
        partial: e.child != NONE && scan.folders[e.child as usize].issues > 0,
    }
}
#[unsafe(no_mangle)]
extern "C" fn dt_child_count(m: &Model, folder: u32) -> usize {
    m.scan
        .read()
        .unwrap()
        .order
        .get(folder as usize)
        .map_or(0, |rows| rows.len())
}
#[unsafe(no_mangle)]
extern "C" fn dt_child(m: &Model, folder: u32, index: usize, out: &mut Row) -> bool {
    let scan = m.scan.read().unwrap();
    let Some(&slot) = scan.order.get(folder as usize).and_then(|s| s.get(index)) else {
        return false;
    };
    *out = make_row(&scan, folder, slot);
    true
}
#[unsafe(no_mangle)]
extern "C" fn dt_entry(m: &Model, folder: u32, slot: u32, out: &mut Row) -> bool {
    let scan = m.scan.read().unwrap();
    let key = Key { folder, slot };
    if key == SCAN_ROOT {
        let name = scan
            .root
            .file_name()
            .unwrap_or(scan.root.as_os_str())
            .as_bytes();
        *out = Row {
            name: name.as_ptr(),
            name_len: name.len(),
            bytes: scan.total(),
            slot: NONE,
            child: 0,
            kind: EntryKind::Directory as u8,
            partial: scan.issues != 0,
        };
        return true;
    }
    if !scan.live(key) {
        return false;
    }
    *out = make_row(&scan, folder, slot);
    true
}
#[unsafe(no_mangle)]
extern "C" fn dt_rows(v: &Listing, count: &mut usize) -> *const Row {
    *count = v.0.len();
    v.0.as_ptr()
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_list_free(p: *mut Listing) {
    unsafe {
        drop(Box::from_raw(p));
    }
}
#[unsafe(no_mangle)]
extern "C" fn dt_path(m: &Model, folder: u32, slot: u32) -> *mut c_char {
    let scan = m.scan.read().unwrap();
    let key = match (folder, slot) {
        (0, NONE) => return string(scan.root.as_os_str().as_bytes()),
        (_, NONE) => match scan.folders.get(folder as usize).and_then(|f| f.parent) {
            Some(parent) => parent,
            None => return ptr::null_mut(),
        },
        _ => Key { folder, slot },
    };
    if scan.live(key) {
        string(scan.path(key).as_os_str().as_bytes())
    } else {
        ptr::null_mut()
    }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_string_free(p: *mut c_char) {
    if !p.is_null() {
        unsafe {
            drop(CString::from_raw(p));
        }
    }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_trash_prepare(
    m: &Model,
    keys: *const Key,
    count: usize,
    impact: &mut trash::TrashImpact,
    err: *mut *mut c_char,
) -> *mut TrashPlan {
    if keys.is_null() || count == 0 {
        error(err, io::Error::other("Select an item first."));
        return ptr::null_mut();
    }
    let keys = unsafe { std::slice::from_raw_parts(keys, count) };
    match m.scan.read().unwrap().review_trash(keys) {
        Ok(review) => {
            *impact = review.impact;
            Box::into_raw(Box::new(TrashPlan {
                owner: m as *const _,
                review,
                multiple_selection: count > 1,
                used: false,
                failed_roots: Vec::new(),
            }))
        }
        Err(e) => {
            error(err, e);
            ptr::null_mut()
        }
    }
}

struct TrashPlan {
    owner: *const Model,
    review: trash::Review,
    multiple_selection: bool,
    used: bool,
    failed_roots: Vec<usize>,
}
#[unsafe(no_mangle)]
extern "C" fn dt_trash_roots(plan: &TrashPlan, count: &mut usize) -> *const Key {
    *count = plan.review.roots.len();
    plan.review.roots.as_ptr()
}
#[unsafe(no_mangle)]
extern "C" fn dt_trash_root_moved(plan: &TrashPlan, index: usize) -> bool {
    plan.used && index < plan.review.roots.len() && plan.failed_roots.binary_search(&index).is_err()
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_trash_plan_free(p: *mut TrashPlan) {
    unsafe {
        drop(Box::from_raw(p));
    }
}

#[repr(C)]
struct TrashResult {
    moved: usize,
    failed: usize,
    first: Key,
}
#[unsafe(no_mangle)]
extern "C" fn dt_trash_perform(
    m: &Model,
    plan: &mut TrashPlan,
    acknowledged: bool,
    report: &mut TrashResult,
    err: *mut *mut c_char,
) -> bool {
    let _move = m.moves.lock().unwrap();
    *report = TrashResult {
        moved: 0,
        failed: 0,
        first: Key {
            folder: NONE,
            slot: NONE,
        },
    };
    let verified = (|| {
        if !ptr::eq(plan.owner, m) || plan.used {
            return Err(io::Error::other("Review this selection again."));
        }
        let scan = m.scan.read().unwrap();
        let fresh = scan.review_trash(&plan.review.roots)?;
        if fresh != plan.review {
            return Err(io::Error::other("The selection changed. Review it again."));
        }
        if plan.multiple_selection {
            fresh.require_acknowledgment(acknowledged)?;
        }
        if fresh.roots.len() > 1 {
            for &key in &fresh.roots {
                if let Err(e) = scan.target(key).and_then(|t| t.check_identity()) {
                    report.first = key;
                    return Err(io::Error::other(format!(
                        "{}: {e}",
                        String::from_utf8_lossy(scan.name(key))
                    )));
                }
            }
        }
        Ok(())
    })();
    if let Err(e) = verified {
        error(err, e);
        return false;
    }
    plan.used = true;
    let mut details = Vec::new();
    for (index, &key) in plan.review.roots.iter().enumerate() {
        let target = m.scan.read().unwrap().target(key);
        match target.and_then(|t| t.move_to_trash()) {
            Ok(()) => {
                m.scan.write().unwrap().detach(key);
                report.moved += 1;
            }
            Err(e) => {
                plan.failed_roots.push(index);
                if report.failed == 0 {
                    report.first = key;
                }
                report.failed += 1;
                if details.len() < 4 {
                    let scan = m.scan.read().unwrap();
                    details.push(format!("{}: {e}", String::from_utf8_lossy(scan.name(key))));
                }
            }
        }
    }
    m.scan.write().unwrap().refresh_order();
    if !details.is_empty() {
        error(err, io::Error::other(details.join("\n")));
    }
    true
}
