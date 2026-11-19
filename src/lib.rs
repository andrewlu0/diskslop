mod bridge;
mod bulk;
mod trash;
use rayon::prelude::*;
use rayon::{Scope, ThreadPoolBuilder};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::{CStr, OsStr, c_char};
use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

const NONE: u32 = u32::MAX;
const LINKED: u8 = 1;
const REMOVED: u8 = 2;

#[derive(Default)]
pub struct Progress {
    seen: AtomicU64,
    cancelled: AtomicBool,
}

impl Progress {
    pub fn count(&self) -> u64 {
        self.seen.load(Ordering::Relaxed)
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }
    fn check(&self) -> io::Result<()> {
        if self.cancelled.load(Ordering::Relaxed) {
            Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "Scan cancelled.",
            ))
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum EntryKind {
    File,
    Directory,
    Link,
    Other,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[repr(C)]
pub struct Key {
    pub folder: u32,
    pub slot: u32,
}

#[derive(Clone)]
struct Entry {
    inode: u64,
    bytes: u64,
    start: usize,
    child: u32,
    len: u16,
    kind: EntryKind,
    flags: u8,
}

#[derive(Default)]
struct Folder {
    parent: Option<Key>,
    entries: Vec<Entry>,
    names: Vec<u8>,
    inode: u64,
    total: u64,
    own_bytes: u64,
    count: u64,
    files: u64,
    contains_mount: bool,
    issues: u64,
    boundaries: u64,
    pre: usize,
    end: usize,
}

impl Folder {
    fn name(&self, slot: usize) -> &[u8] {
        let e = &self.entries[slot];
        &self.names[e.start..e.start + usize::from(e.len)]
    }
    fn push(&mut self, name: &[u8], facts: bulk::Facts) {
        if facts.kind == EntryKind::Directory && matches!(name, b".Trash" | b".Trashes") {
            return;
        }
        let Ok(len) = u16::try_from(name.len()) else {
            self.issues += 1;
            return;
        };
        self.entries.push(Entry {
            inode: facts.inode,
            bytes: facts.bytes,
            start: self.names.len(),
            len,
            child: NONE,
            flags: if facts.linked { LINKED } else { 0 },
            kind: facts.kind,
        });
        self.names.extend_from_slice(name);
    }
}

struct LinkGroup {
    bytes: u64,
    owner: Key,
    members: Vec<Key>,
}

pub struct Inventory {
    root: PathBuf,
    device: u64,
    folders: Vec<Folder>,
    groups: HashMap<u64, LinkGroup>,
    owners: BTreeMap<(usize, u32), u64>,
    order: Vec<Vec<u32>>,
    dirty_order: Vec<u32>,
    protected: Vec<trash::ProtectedFolder>,
    pub issues: u64,
    pub boundaries: u64,
}

struct Build<'a> {
    folders: Mutex<Vec<Folder>>,
    root_error: Mutex<Option<io::Error>>,
    progress: &'a Progress,
    device: u64,
    reuse: Option<Reuse<'a>>,
    changed_links: Mutex<HashMap<u64, u64>>,
}

struct Reuse<'a> {
    scan: &'a Inventory,
    relist: HashSet<u32>,
    descend: HashSet<u32>,
}
impl Reuse<'_> {
    fn copy_folder(&self, id: u32) -> Folder {
        let old = &self.scan.folders[id as usize];
        let mut entries = old.entries.clone();
        entries.retain(|e| e.flags & REMOVED == 0);
        for e in &mut entries {
            if e.flags & LINKED != 0
                && let Some(g) = self.scan.groups.get(&e.inode)
            {
                e.bytes = g.bytes;
            }
        }
        Folder {
            entries,
            names: old.names.clone(),
            inode: old.inode,
            total: old.own_bytes,
            own_bytes: old.own_bytes,
            issues: old.issues,
            boundaries: old.boundaries,
            ..Folder::default()
        }
    }
}

struct Job {
    id: u32,
    prior: u32,
    inode: u64,
    path: PathBuf,
}

fn visit<'s>(scope: &Scope<'s>, build: &'s Build<'_>, job: Job) {
    if build.progress.check().is_err() {
        return;
    }
    let prior = build
        .reuse
        .as_ref()
        .filter(|r| job.prior != NONE && !r.descend.contains(&job.prior));
    let cached = prior.filter(|r| !r.relist.contains(&job.prior));
    let mut folder = cached.map_or_else(
        || Folder {
            inode: job.inode,
            ..Folder::default()
        },
        |r| r.copy_folder(job.prior),
    );
    let result = if cached.is_some() {
        Ok(())
    } else {
        bulk::open_dir(&job.path, build.device, job.inode).and_then(|(fd, own_bytes)| {
            folder.own_bytes = own_bytes;
            folder.total = own_bytes;
            bulk::enumerate(&fd, build.device, &mut folder, build.progress)
        })
    };
    if let Err(err) = result {
        if job.id == 0 && folder.entries.is_empty() {
            *build.root_error.lock().unwrap() = Some(err);
            return;
        }
        folder.issues += 1;
    }
    if build.progress.check().is_err() {
        return;
    }
    build
        .progress
        .seen
        .fetch_add(folder.entries.len() as u64, Ordering::Relaxed);
    let mut next = Vec::new();
    let old_children = prior.filter(|_| cached.is_none()).map(|r| {
        r.scan.folders[job.prior as usize]
            .entries
            .iter()
            .filter(|e| e.kind == EntryKind::Directory && e.flags & REMOVED == 0)
            .map(|e| (e.inode, e.child))
            .collect::<HashMap<_, _>>()
    });
    if build.reuse.is_some() && cached.is_none() {
        let changed: Vec<_> = folder
            .entries
            .iter()
            .filter(|e| e.flags & LINKED != 0)
            .map(|e| (e.inode, e.bytes))
            .collect();
        if !changed.is_empty() {
            build.changed_links.lock().unwrap().extend(changed);
        }
    }
    for (slot, entry) in folder.entries.iter().enumerate() {
        if entry.kind == EntryKind::Directory {
            let path = job.path.join(OsStr::from_bytes(folder.name(slot)));
            next.push((
                slot,
                Job {
                    id: 0,
                    prior: old_children
                        .as_ref()
                        .and_then(|s| s.get(&entry.inode).copied())
                        .unwrap_or(entry.child),
                    inode: entry.inode,
                    path,
                },
            ));
        }
    }
    {
        let mut dirs = build.folders.lock().unwrap();
        for (slot, child) in &mut next {
            child.id = u32::try_from(dirs.len()).expect("Too many directories");
            folder.entries[*slot].child = child.id;
            dirs.push(Folder {
                parent: Some(Key {
                    folder: job.id,
                    slot: *slot as u32,
                }),
                ..Folder::default()
            });
        }
        folder.parent = dirs[job.id as usize].parent;
        dirs[job.id as usize] = folder;
    }
    for (_, child) in next {
        scope.spawn(move |s| visit(s, build, child));
    }
}

pub fn default_threads() -> usize {
    std::thread::available_parallelism()
        .map_or(4, usize::from)
        .clamp(1, 8)
}

impl Inventory {
    pub fn scan(path: &Path, threads: usize, progress: &Progress) -> io::Result<Self> {
        Self::build(path, threads, progress, false)
    }
    fn build(path: &Path, threads: usize, progress: &Progress, index: bool) -> io::Result<Self> {
        Self::build_reusing(path, threads, progress, index, None)
    }
    fn refreshed(&self, keys: &[Key], progress: &Progress) -> io::Result<Self> {
        let mut reuse = Reuse {
            scan: self,
            relist: HashSet::new(),
            descend: HashSet::new(),
        };
        for &key in keys {
            if !self.live(key) {
                return Err(io::Error::other("The selection has changed."));
            }
            reuse.relist.insert(key.folder);
            let entry = self.entry(key);
            if entry.kind == EntryKind::Directory {
                reuse.descend.insert(entry.child);
            }
        }
        Self::build_reusing(&self.root, default_threads(), progress, true, Some(reuse))
    }
    fn refresh_paths(&self, paths: &[u8], progress: &Progress) -> io::Result<Self> {
        let mut reuse = Reuse {
            scan: self,
            relist: HashSet::new(),
            descend: HashSet::new(),
        };
        for raw in paths.split(|&v| v == 0).filter(|p| !p.is_empty()) {
            let path = Path::new(OsStr::from_bytes(raw));
            let Ok(relative) = path.strip_prefix(&self.root) else {
                return Self::build(&self.root, default_threads(), progress, true);
            };
            let mut dir = 0;
            let mut parts = relative.iter().peekable();
            while let Some(part) = parts.next() {
                let f = &self.folders[dir as usize];
                let found = f
                    .entries
                    .iter()
                    .enumerate()
                    .find(|(i, e)| e.flags & REMOVED == 0 && f.name(*i) == part.as_bytes());
                if let Some((_, e)) = found
                    && e.kind == EntryKind::Directory
                {
                    if parts.peek().is_some() {
                        dir = e.child;
                        continue;
                    }
                    reuse.descend.insert(e.child);
                }
                break;
            }
            reuse.relist.insert(dir);
        }
        Self::build_reusing(&self.root, default_threads(), progress, true, Some(reuse))
    }
    fn build_reusing(
        path: &Path,
        threads: usize,
        progress: &Progress,
        index: bool,
        reuse: Option<Reuse<'_>>,
    ) -> io::Result<Self> {
        let root = fs::canonicalize(path)?;
        let meta = fs::metadata(&root)?;
        if !meta.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::NotADirectory,
                "Choose a directory.",
            ));
        }
        let reuse =
            reuse.filter(|r| (r.scan.device, r.scan.folders[0].inode) == (meta.dev(), meta.ino()));
        let root_prior = if reuse.is_some() { 0 } else { NONE };
        let build = Build {
            folders: Mutex::new(vec![Folder::default()]),
            root_error: Mutex::default(),
            progress,
            device: meta.dev(),
            reuse,
            changed_links: Mutex::default(),
        };
        let workers = ThreadPoolBuilder::new()
            .num_threads(threads.clamp(1, 64))
            .build()
            .map_err(io::Error::other)?;
        workers.scope(|s| {
            visit(
                s,
                &build,
                Job {
                    id: 0,
                    prior: root_prior,
                    inode: meta.ino(),
                    path: root.clone(),
                },
            )
        });
        progress.check()?;
        if let Some(err) = build.root_error.into_inner().unwrap() {
            return Err(err);
        }
        let mut inventory = Self {
            root,
            device: meta.dev(),
            folders: build.folders.into_inner().unwrap(),
            groups: HashMap::new(),
            owners: BTreeMap::new(),
            order: Vec::new(),
            dirty_order: Vec::new(),
            protected: Vec::new(),
            issues: 0,
            boundaries: 0,
        };
        let links = build.changed_links.into_inner().unwrap();
        if !links.is_empty() {
            for f in &mut inventory.folders {
                for e in &mut f.entries {
                    if e.kind != EntryKind::Directory
                        && let Some(&bytes) = links.get(&e.inode)
                    {
                        e.flags |= LINKED;
                        e.bytes = bytes;
                    }
                }
            }
        }
        inventory.finish(progress)?;
        inventory.protected = trash::protected_folders(&inventory);
        if index {
            inventory.order = workers.install(|| {
                (0..inventory.folders.len())
                    .into_par_iter()
                    .map(|id| {
                        progress.check()?;
                        Ok(inventory.build_order(id as u32, usize::MAX))
                    })
                    .collect::<io::Result<Vec<_>>>()
            })?;
        }
        Ok(inventory)
    }

    fn finish(&mut self, progress: &Progress) -> io::Result<()> {
        let mut ordinal = 0;
        let mut stack = vec![(0usize, false)];
        while let Some((dir, leaving)) = stack.pop() {
            if leaving {
                self.folders[dir].end = ordinal;
                continue;
            }
            progress.check()?;
            let f = &mut self.folders[dir];
            f.pre = ordinal;
            ordinal += 1;
            stack.push((dir, true));
            self.issues += f.issues;
            self.boundaries += f.boundaries;
            f.count = f.entries.len() as u64;
            f.contains_mount = f.boundaries != 0;
            for (slot, e) in f.entries.iter_mut().enumerate() {
                if e.kind == EntryKind::Directory {
                    stack.push((e.child as usize, false));
                    continue;
                }
                if e.flags & LINKED != 0 {
                    let key = Key {
                        folder: dir as u32,
                        slot: slot as u32,
                    };
                    let group = self.groups.entry(e.inode).or_insert_with(|| LinkGroup {
                        bytes: e.bytes,
                        owner: key,
                        members: Vec::new(),
                    });
                    group.members.push(key);
                    if group.owner != key {
                        e.bytes = 0;
                    }
                }
                f.files += 1;
                f.total += e.bytes;
            }
        }
        self.groups.retain(|_, g| g.members.len() > 1);
        for (inode, group) in &self.groups {
            self.owners.insert(
                (
                    self.folders[group.owner.folder as usize].pre,
                    group.owner.slot,
                ),
                *inode,
            );
        }
        // A parent's slot is reserved before its children can be scheduled.
        for id in (1..self.folders.len()).rev() {
            let f = &self.folders[id];
            let (bytes, count, files, has_mount) = (f.total, f.count, f.files, f.contains_mount);
            let parent = f.parent.unwrap().folder as usize;
            self.folders[parent].total += bytes;
            self.folders[parent].count += count;
            self.folders[parent].files += files;
            self.folders[parent].contains_mount |= has_mount;
        }
        Ok(())
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn total(&self) -> u64 {
        self.folders[0].total
    }
    pub fn count(&self) -> u64 {
        self.folders[0].count
    }
    fn entry(&self, key: Key) -> &Entry {
        &self.folders[key.folder as usize].entries[key.slot as usize]
    }
    pub fn name(&self, key: Key) -> &[u8] {
        self.folders[key.folder as usize].name(key.slot as usize)
    }
    pub fn kind(&self, key: Key) -> EntryKind {
        self.entry(key).kind
    }
    pub fn size(&self, key: Key) -> u64 {
        let e = self.entry(key);
        if e.kind == EntryKind::Directory {
            self.folders[e.child as usize].total
        } else {
            e.bytes
        }
    }
    pub fn sorted_children(&self, folder: u32) -> Vec<u32> {
        self.largest_children(folder, usize::MAX)
    }
    fn largest_children(&self, folder: u32, limit: usize) -> Vec<u32> {
        if let Some(slots) = self.order.get(folder as usize) {
            return slots[..slots.len().min(limit)].to_vec();
        }
        self.build_order(folder, limit)
    }
    fn build_order(&self, folder: u32, limit: usize) -> Vec<u32> {
        let Some(f) = self.folders.get(folder as usize) else {
            return Vec::new();
        };
        let mut slots: Vec<_> = f
            .entries
            .iter()
            .enumerate()
            .filter(|(_, e)| e.flags & REMOVED == 0)
            .map(|(i, _)| i as u32)
            .collect();
        let compare = |&a: &u32, &b: &u32| {
            self.size(Key { folder, slot: b })
                .cmp(&self.size(Key { folder, slot: a }))
                .then_with(|| f.name(a as usize).cmp(f.name(b as usize)))
        };
        if limit < slots.len() {
            slots.select_nth_unstable_by(limit, compare);
            slots.truncate(limit);
        }
        slots.sort_unstable_by(compare);
        slots
    }
    fn live_folder(&self, mut dir: u32) -> bool {
        while let Some(parent) = self.folders[dir as usize].parent {
            if self.entry(parent).flags & REMOVED != 0 {
                return false;
            }
            dir = parent.folder;
        }
        true
    }
    fn live(&self, key: Key) -> bool {
        self.folders
            .get(key.folder as usize)
            .and_then(|f| f.entries.get(key.slot as usize))
            .is_some_and(|e| e.flags & REMOVED == 0)
            && self.live_folder(key.folder)
    }
    pub fn path(&self, mut key: Key) -> PathBuf {
        let mut parts = vec![self.name(key)];
        while let Some(parent) = self.folders[key.folder as usize].parent {
            key = parent;
            parts.push(self.name(key));
        }
        let mut path = self.root.clone();
        for part in parts.into_iter().rev() {
            path.push(OsStr::from_bytes(part));
        }
        path
    }

    fn adjust(&mut self, mut dir: u32, bytes: u64, count: u64, files: u64, add: bool) {
        loop {
            if !self.order.is_empty() {
                self.dirty_order.push(dir);
            }
            let f = &mut self.folders[dir as usize];
            if add {
                f.total += bytes;
                f.count += count;
                f.files += files;
            } else {
                f.total -= bytes;
                f.count -= count;
                f.files -= files;
            }
            let Some(parent) = f.parent else {
                break;
            };
            dir = parent.folder;
        }
    }

    fn detach(&mut self, key: Key) {
        let e = self.entry(key);
        let (bytes, count, files, displaced) = if e.kind == EntryKind::Directory {
            let f = &self.folders[e.child as usize];
            (
                f.total,
                f.count + 1,
                f.files,
                self.owners
                    .range((f.pre, 0)..(f.end, 0))
                    .map(|(_, &ino)| ino)
                    .collect::<Vec<_>>(),
            )
        } else {
            (
                e.bytes,
                1,
                1,
                self.groups
                    .get(&e.inode)
                    .filter(|g| g.owner == key)
                    .map(|_| e.inode)
                    .into_iter()
                    .collect(),
            )
        };
        self.folders[key.folder as usize].entries[key.slot as usize].flags |= REMOVED;
        self.adjust(key.folder, bytes, count, files, false);
        for inode in displaced {
            let g = &self.groups[&inode];
            let old = g.owner;
            self.owners
                .remove(&(self.folders[old.folder as usize].pre, old.slot));
            if let Some(next) = g.members.iter().copied().find(|&k| self.live(k)) {
                let bytes = g.bytes;
                self.folders[next.folder as usize].entries[next.slot as usize].bytes = bytes;
                self.groups.get_mut(&inode).unwrap().owner = next;
                self.owners
                    .insert((self.folders[next.folder as usize].pre, next.slot), inode);
                self.adjust(next.folder, bytes, 0, 0, true);
            } else {
                self.groups.remove(&inode);
            }
        }
    }

    fn target(&self, key: Key) -> io::Result<Target> {
        if !self.live(key) {
            return Err(io::Error::other("This item is no longer in the scan."));
        }
        let e = self.entry(key);
        let path = self.path(key);
        if path
            .components()
            .any(|c| matches!(c.as_os_str().as_bytes(), b".Trash" | b".Trashes"))
        {
            return Err(io::Error::other(
                "This item is already in a Trash directory.",
            ));
        }
        Ok(Target {
            path,
            device: self.device,
            parent_inode: self.folders[key.folder as usize].inode,
            inode: e.inode,
            directory: e.kind == EntryKind::Directory,
        })
    }

    pub fn trash(&mut self, key: Key) -> io::Result<()> {
        let review = self.review_trash(&[key])?;
        review.require_acknowledgment(false)?;
        self.target(key)?.move_to_trash()?;
        self.detach(key);
        self.refresh_order();
        Ok(())
    }
    fn refresh_order(&mut self) {
        let mut dirty = std::mem::take(&mut self.dirty_order);
        dirty.sort_unstable();
        dirty.dedup();
        for dir in dirty {
            self.order[dir as usize] = self.build_order(dir, usize::MAX);
        }
    }
}

struct Target {
    path: PathBuf,
    device: u64,
    parent_inode: u64,
    inode: u64,
    directory: bool,
}

unsafe extern "C" {
    fn dt_system_trash(path: *const c_char, directory: bool) -> *mut c_char;
}

impl Target {
    fn check_identity(&self) -> io::Result<()> {
        let parent = self
            .path
            .parent()
            .ok_or_else(|| io::Error::other("The scan root cannot be moved."))?;
        let (fd, _) = bulk::open_dir(parent, self.device, self.parent_inode)?;
        let name = bulk::checked_name(self.path.file_name().unwrap().as_bytes())?;
        let stat = bulk::stat_at(&fd, &name)?;
        if (u64::from(stat.st_dev as u32), stat.st_ino) != (self.device, self.inode)
            || (stat.st_mode & libc::S_IFMT == libc::S_IFDIR) != self.directory
        {
            return Err(io::Error::other(
                "This item has changed since the scan. Rescan before moving it.",
            ));
        }
        Ok(())
    }
    fn move_to_trash(&self) -> io::Result<()> {
        self.check_identity()?;
        let path = bulk::checked_name(self.path.as_os_str().as_bytes())?;
        let error = unsafe { dt_system_trash(path.as_ptr(), self.directory) };
        if error.is_null() {
            Ok(())
        } else {
            let message = unsafe { CStr::from_ptr(error) }
                .to_string_lossy()
                .into_owned();
            unsafe {
                libc::free(error.cast());
            }
            Err(io::Error::other(message))
        }
    }
}
