use super::*;
use std::ffi::CString;
use std::ptr;
use std::sync::RwLock;
#[path = "bookmark.rs"]
mod bookmark;
#[path = "treemap.rs"]
mod treemap;

struct Model {
    scan: RwLock<Inventory>,
    estimated_bytes: usize,
    moves: Mutex<()>,
}
struct Listing(Vec<Row>);

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
extern "C" fn dt_cancel(p: &Progress) {
    p.cancel();
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
    let path = Path::new(OsStr::from_bytes(
        unsafe { CStr::from_ptr(path) }.to_bytes(),
    ));
    wrap(Inventory::build(path, default_threads(), p, true), err)
}
fn wrap(result: io::Result<Inventory>, err: *mut *mut c_char) -> *mut Model {
    match result {
        Ok(scan) => {
            let estimated_bytes = scan.folders.capacity() * std::mem::size_of::<Folder>()
                + scan
                    .folders
                    .iter()
                    .map(|f| {
                        f.entries.capacity() * std::mem::size_of::<Entry>() + f.names.capacity()
                    })
                    .sum::<usize>()
                + scan
                    .order
                    .iter()
                    .map(|v| {
                        v.capacity() * std::mem::size_of::<u32>() + std::mem::size_of::<Vec<u32>>()
                    })
                    .sum::<usize>()
                + scan
                    .groups
                    .values()
                    .map(|g| g.members.capacity() * std::mem::size_of::<Key>() + 128)
                    .sum::<usize>();
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
        .map_or(0, Vec::len)
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
    if !scan.live(Key { folder, slot }) {
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
    if slot == NONE {
        return string(scan.root.as_os_str().as_bytes());
    }
    let key = Key { folder, slot };
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
                used: false,
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
    used: bool,
}
#[unsafe(no_mangle)]
extern "C" fn dt_trash_roots(plan: &TrashPlan, count: &mut usize) -> *const Key {
    *count = plan.review.roots.len();
    plan.review.roots.as_ptr()
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
        fresh.require_acknowledgment(acknowledged)?;
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
    for &key in &plan.review.roots {
        let target = m.scan.read().unwrap().target(key);
        match target.and_then(|t| t.move_to_trash()) {
            Ok(()) => {
                m.scan.write().unwrap().detach(key);
                report.moved += 1;
            }
            Err(e) => {
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
