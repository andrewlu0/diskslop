mod bridge;
mod bulk;
mod largest;
mod pages;
mod preview;
use pages::Pages;
mod scan_policy;
mod snapshot;
pub use scan_policy::default_threads;
mod trash;
use rayon::prelude::*;
use rayon::{Scope, ThreadPoolBuilder};
use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::{CStr, OsStr, c_char};
use std::fs;
use std::io;
use std::ops::{Deref, DerefMut};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use unicode_normalization::UnicodeNormalization;

const NONE: u32 = u32::MAX;
const LINKED: u8 = 1;
const REMOVED: u8 = 2;
const EXECUTABLE: u8 = 4;
const FINDER_BUNDLE: u8 = 8;

#[derive(Default)]
pub struct Progress {
    seen: AtomicU64,
    cancelled: AtomicBool,
    largest: largest::LiveRanking,
    workspace: preview::Subscription,
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

#[derive(Clone, Eq, PartialEq)]
struct Entry {
    finder_type: u32,
    inode: u64,
    bytes: u64,
    start: usize,
    child: u32,
    len: u16,
    kind: EntryKind,
    flags: u8,
}

#[derive(Clone)]
enum SharedVec<T> {
    Building(Vec<T>),
    Indexed(Arc<Vec<T>>),
}
impl<T> Default for SharedVec<T> {
    fn default() -> Self {
        Self::Building(Vec::new())
    }
}
impl<T> Deref for SharedVec<T> {
    type Target = Vec<T>;
    fn deref(&self) -> &Vec<T> {
        match self {
            Self::Building(v) => v,
            Self::Indexed(v) => v,
        }
    }
}
impl<T: Clone> DerefMut for SharedVec<T> {
    fn deref_mut(&mut self) -> &mut Vec<T> {
        match self {
            Self::Building(v) => v,
            Self::Indexed(v) => Arc::make_mut(v),
        }
    }
}
impl<T> SharedVec<T> {
    fn freeze(&mut self) {
        if let Self::Building(v) = self
            && !v.is_empty()
        {
            *self = Self::Indexed(Arc::new(std::mem::take(v)));
        }
    }
}

#[derive(Default, Clone)]
struct Folder {
    parent: Option<Key>,
    prior_leaf: Option<u32>,
    entries: SharedVec<Entry>,
    dates: Option<SharedVec<bulk::FileDates>>,
    names: SharedVec<u8>,
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
    fn shared_leaf(&self, previous: &Inventory) -> Option<u32> {
        let id = self.prior_leaf?;
        let old = previous.folders.get(id as usize)?;
        (self.entries.as_ptr() == old.entries.as_ptr()
            && self.entries.len() == old.entries.len()
            && self.names.as_ptr() == old.names.as_ptr())
        .then_some(id)
    }
    fn freeze(&mut self) {
        self.entries.freeze();
        self.names.freeze();
        if let Some(dates) = &mut self.dates {
            dates.freeze();
        }
    }
    fn name(&self, slot: usize) -> &[u8] {
        let e = &self.entries[slot];
        &self.names[e.start..e.start + usize::from(e.len)]
    }
    fn named_entry(&self, name: &[u8]) -> Option<(usize, &Entry)> {
        let live = self
            .entries
            .iter()
            .enumerate()
            .filter(|(_, e)| e.flags & REMOVED == 0);
        if let exact @ Some(_) = live.clone().find(|(i, _)| self.name(*i) == name) {
            return exact;
        }
        if name.is_ascii() {
            return None;
        }
        let normalized: String = std::str::from_utf8(name).ok()?.nfc().collect();
        let mut candidates = live.filter(|(i, _)| {
            std::str::from_utf8(self.name(*i)).is_ok_and(|s| s.nfc().eq(normalized.chars()))
        });
        let first = candidates.next()?;
        candidates.next().is_none().then_some(first)
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
            finder_type: facts.finder_type,
            inode: facts.inode,
            bytes: facts.bytes,
            start: self.names.len(),
            len,
            child: NONE,
            flags: (u8::from(facts.linked) * LINKED)
                | (u8::from(facts.executable) * EXECUTABLE)
                | (u8::from(facts.bundle) * FINDER_BUNDLE),
            kind: facts.kind,
        });
        self.names.extend_from_slice(name);
        if let Some(dates) = &mut self.dates {
            dates.push(facts.dates);
        }
    }
}

#[derive(Clone)]
struct LinkGroup {
    bytes: u64,
    owner: Key,
    members: Vec<Key>,
}

#[derive(Clone)]
pub struct Inventory {
    root: PathBuf,
    device: u64,
    folders: Pages<Folder>,
    revision: Arc<()>,
    scan_id: Option<Arc<()>>,
    provisional: bool,
    delta: Option<(Arc<()>, Vec<u32>)>,
    rebuilt_from: Option<Arc<()>>,
    groups: Arc<HashMap<u64, LinkGroup>>,
    owners: Arc<BTreeMap<(usize, u32), u64>>,
    order: Pages<Arc<[u32]>>,
    dirty_order: Vec<u32>,
    protected: Vec<trash::ProtectedFolder>,
    pub issues: u64,
    pub boundaries: u64,
}

struct Build<'a> {
    file_kinds: bool,
    feed: Option<Arc<preview::Feed>>,
    budget: scan_policy::ScanBudget,
    folders: Mutex<Vec<Folder>>,
    root_error: Mutex<Option<io::Error>>,
    progress: &'a Progress,
    device: u64,
    reuse: Option<Reuse<'a>>,
    dirty_branches: HashSet<u32>,
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
        let mut dates = old.dates.clone();
        if entries.iter().any(|e| e.flags & REMOVED != 0) {
            if let Some(values) = &mut dates {
                *values = SharedVec::Building(
                    values
                        .iter()
                        .zip(entries.iter())
                        .filter(|(_, e)| e.flags & REMOVED == 0)
                        .map(|(date, _)| *date)
                        .collect(),
                );
            }
            entries.retain(|e| e.flags & REMOVED == 0);
        }
        let mut leaf = true;
        for slot in 0..entries.len() {
            let e = &entries[slot];
            leaf &= e.child == NONE;
            if e.flags & LINKED != 0
                && let Some(g) = self.scan.groups.get(&e.inode)
                && e.bytes != g.bytes
            {
                entries[slot].bytes = g.bytes;
            }
        }
        Folder {
            prior_leaf: leaf.then_some(id),
            entries,
            dates,
            names: old.names.clone(),
            inode: old.inode,
            total: old.own_bytes,
            own_bytes: old.own_bytes,
            issues: old.issues,
            boundaries: old.boundaries,
            ..Folder::default()
        }
    }
    fn copy_subtree(&self, build: &Build<'_>, root: &Job) {
        let mut dirs = build.folders.lock().unwrap();
        let mut pending = vec![(root.prior, root.id)];
        let mut count = 0;
        while let Some((old, id)) = pending.pop() {
            if build.progress.cancelled.load(Ordering::Relaxed) {
                return;
            }
            let mut folder = self.copy_folder(old);
            folder.parent = dirs[id as usize].parent;
            count += folder.entries.len() as u64;
            for slot in 0..folder.entries.len() {
                let prior = folder.entries[slot].child;
                if prior == NONE {
                    continue;
                }
                let child = u32::try_from(dirs.len()).expect("Too many directories");
                if prior != child {
                    folder.entries[slot].child = child;
                }
                dirs.push(Folder {
                    parent: Some(Key {
                        folder: id,
                        slot: slot as u32,
                    }),
                    ..Default::default()
                });
                pending.push((prior, child));
            }
            dirs[id as usize] = folder;
        }
        build.progress.seen.fetch_add(count, Ordering::Relaxed);
    }
}

struct Job {
    id: u32,
    prior: u32,
    inode: u64,
    path: PathBuf,
}

fn visit<'s>(scope: &Scope<'s>, build: &'s Build<'_>, job: Job) {
    let Ok(permit) = build.budget.enter(build.progress) else {
        return;
    };
    let prior = build
        .reuse
        .as_ref()
        .filter(|r| job.prior != NONE && !r.descend.contains(&job.prior));
    let cached = prior.filter(|r| !r.relist.contains(&job.prior));
    if let Some(cached) = cached
        && !build.dirty_branches.contains(&job.prior)
    {
        cached.copy_subtree(build, &job);
        return;
    }
    let mut folder = cached.map_or_else(
        || Folder {
            inode: job.inode,
            dates: build.file_kinds.then(SharedVec::default),
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
            let mut last_epoch = build
                .feed
                .as_ref()
                .filter(|_| job.id != 0)
                .map_or(0, |f| f.epoch.load(Ordering::Relaxed));
            let mut reserved = 0;
            let mut last_capture: Option<std::time::Instant> = None;
            bulk::enumerate(
                &fd,
                build.device,
                &mut folder,
                build.progress,
                build.file_kinds,
                &job.path,
                |folder| {
                    let Some(feed) = &build.feed else { return };
                    let epoch = feed.epoch.load(Ordering::Relaxed);
                    let length = folder.entries.len();
                    if length < 256 || length == reserved || epoch == last_epoch {
                        return;
                    }
                    if length - reserved < reserved / 8
                        && last_capture.is_some_and(|t| t.elapsed().as_secs() == 0)
                    {
                        return;
                    }
                    last_epoch = epoch;
                    last_capture = Some(std::time::Instant::now());
                    let mut dirs = build.folders.lock().unwrap();
                    for (slot, entry) in folder.entries.iter_mut().enumerate().skip(reserved) {
                        if entry.kind == EntryKind::Directory {
                            entry.child = reserve_directory(&mut dirs, job.id, slot, entry.inode);
                        }
                    }
                    reserved = folder.entries.len();
                    drop(dirs);
                    let mut partial = folder.clone();
                    partial.freeze();
                    feed.publish(job.id, partial);
                },
            )
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
    if cached.is_some() {
        build
            .progress
            .seen
            .fetch_add(folder.entries.len() as u64, Ordering::Relaxed);
    }
    let mut next = Vec::new();
    let old_children = prior.filter(|_| cached.is_none()).map(|r| {
        r.scan.folders[job.prior as usize]
            .entries
            .iter()
            .enumerate()
            .filter(|(_, e)| e.kind == EntryKind::Directory && e.flags & REMOVED == 0)
            .map(|(i, e)| {
                (
                    (e.inode, r.scan.folders[job.prior as usize].name(i)),
                    e.child,
                )
            })
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
                        .and_then(|s| s.get(&(entry.inode, folder.name(slot))).copied())
                        .unwrap_or(entry.child),
                    inode: entry.inode,
                    path,
                },
            ));
        }
    }
    let published = {
        let mut dirs = build.folders.lock().unwrap();
        for (slot, child) in &mut next {
            let assigned = folder.entries[*slot].child;
            child.id = if build.feed.is_some() && assigned != NONE {
                assigned
            } else {
                reserve_directory(&mut dirs, job.id, *slot, child.inode)
            };
            if assigned != child.id {
                folder.entries[*slot].child = child.id;
            }
        }
        folder.parent = dirs[job.id as usize].parent;
        if build.feed.is_some() {
            folder.prior_leaf = next.is_empty().then_some(job.id);
            folder.freeze();
        }
        dirs[job.id as usize] = folder;
        build
            .feed
            .as_ref()
            .map(|feed| (feed, dirs[job.id as usize].clone()))
    };
    if let Some((feed, snapshot)) = published {
        feed.publish(job.id, snapshot);
    }
    drop(permit);
    for (_, child) in next {
        scope.spawn(move |s| visit(s, build, child));
    }
}

fn reserve_directory(dirs: &mut Vec<Folder>, folder: u32, slot: usize, inode: u64) -> u32 {
    let child = u32::try_from(dirs.len()).expect("Too many directories");
    dirs.push(Folder {
        parent: Some(Key {
            folder,
            slot: slot as u32,
        }),
        inode,
        ..Folder::default()
    });
    child
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
        self.apply_refresh(reuse, progress).map(Cow::into_owned)
    }
    fn refresh_paths(&self, paths: &[u8], progress: &Progress) -> io::Result<Self> {
        self.refresh_changes(&[], paths, false, progress)
            .map(Cow::into_owned)
    }
    fn refresh_changes(
        &self,
        shallow: &[u8],
        recursive: &[u8],
        retry_issues: bool,
        progress: &Progress,
    ) -> io::Result<Cow<'_, Self>> {
        let mut reuse = Reuse {
            scan: self,
            relist: HashSet::new(),
            descend: HashSet::new(),
        };
        if retry_issues && self.issues > 0 {
            reuse.relist.insert(0);
            for (id, folder) in self.folders.iter().enumerate() {
                if folder.issues != 0 && self.live_folder(id as u32) {
                    reuse.relist.insert(id as u32);
                    if let Some(parent) = folder.parent {
                        reuse.relist.insert(parent.folder);
                    }
                }
            }
        }
        for (raw, subtree) in
            [(shallow, false), (recursive, true)]
                .into_iter()
                .flat_map(|(paths, subtree)| {
                    paths
                        .split(|&v| v == 0)
                        .filter(|p| !p.is_empty())
                        .map(move |p| (p, subtree))
                })
        {
            let path = Path::new(OsStr::from_bytes(raw));
            let Ok(relative) = path.strip_prefix(&self.root) else {
                return Self::build(&self.root, default_threads(), progress, true).map(Cow::Owned);
            };
            let mut dir = 0;
            let mut parts = relative.iter().peekable();
            if subtree && parts.peek().is_none() {
                return Self::build(&self.root, default_threads(), progress, true).map(Cow::Owned);
            }
            while let Some(part) = parts.next() {
                let f = &self.folders[dir as usize];
                if let Some((_, e)) = f.named_entry(part.as_bytes())
                    && e.kind == EntryKind::Directory
                {
                    if parts.peek().is_some() || !subtree {
                        dir = e.child;
                        continue;
                    }
                    reuse.descend.insert(e.child);
                }
                break;
            }
            reuse.relist.insert(dir);
        }
        self.apply_refresh(reuse, progress)
    }
    fn apply_refresh(&self, reuse: Reuse<'_>, progress: &Progress) -> io::Result<Cow<'_, Self>> {
        if reuse.descend.is_empty()
            && !self.order.is_empty()
            && fs::metadata(&self.root)
                .is_ok_and(|m| (m.dev(), m.ino()) == (self.device, self.folders[0].inode))
            && let Some(next) = self.patch_directories(&reuse.relist, progress)?
        {
            return Ok(next);
        }
        Self::build_reusing(&self.root, default_threads(), progress, true, Some(reuse))
            .map(Cow::Owned)
    }

    fn patch_directories(
        &self,
        changed: &HashSet<u32>,
        progress: &Progress,
    ) -> io::Result<Option<Cow<'_, Self>>> {
        let mut updates = Vec::with_capacity(changed.len());
        for &id in changed {
            progress.check()?;
            let old = &self.folders[id as usize];
            if old.entries.iter().any(|e| e.flags & REMOVED != 0) {
                return Ok(None);
            }
            let path = old
                .parent
                .map_or_else(|| self.root.clone(), |p| self.path(p));
            let (fd, own_bytes) = match bulk::open_dir(&path, self.device, old.inode) {
                Ok(opened) => opened,
                Err(error)
                    if error.kind() == io::ErrorKind::PermissionDenied
                        && old.issues != 0
                        && old.entries.is_empty() =>
                {
                    continue;
                }
                Err(_) => return Ok(None),
            };
            let mut fresh = Folder {
                dates: Some(SharedVec::default()),
                own_bytes,
                ..Folder::default()
            };
            let read = bulk::enumerate(&fd, self.device, &mut fresh, progress, true, &path, |_| {});
            if read
                .as_ref()
                .is_err_and(|e| e.kind() == io::ErrorKind::PermissionDenied)
                && old.issues != 0
                && old.entries.is_empty()
                && fresh.entries.is_empty()
            {
                continue;
            }
            if read.is_err() || fresh.issues != old.issues || fresh.boundaries != old.boundaries {
                progress.check()?;
                return Ok(None);
            }
            let mut linked = 0;
            for (slot, prior) in old
                .entries
                .iter()
                .enumerate()
                .filter(|(_, e)| e.flags & LINKED != 0)
            {
                let Some(entry) = fresh.entries.get(slot) else {
                    return Ok(None);
                };
                let allocated = self
                    .groups
                    .get(&prior.inode)
                    .map_or(prior.bytes, |g| g.bytes);
                if entry.flags & LINKED == 0
                    || entry.inode != prior.inode
                    || fresh.name(slot) != old.name(slot)
                    || entry.bytes != allocated
                {
                    return Ok(None);
                }
                fresh.entries[slot].bytes = prior.bytes;
                linked += 1;
            }
            if linked
                != fresh
                    .entries
                    .iter()
                    .filter(|e| e.flags & LINKED != 0)
                    .count()
            {
                return Ok(None);
            }
            let mut children: HashMap<_, _> = old
                .entries
                .iter()
                .enumerate()
                .filter(|(_, e)| e.child != NONE)
                .map(|(slot, e)| (e.inode, (old.name(slot), e.child)))
                .collect();
            for slot in 0..fresh.entries.len() {
                let entry = &fresh.entries[slot];
                if entry.kind == EntryKind::Directory {
                    let Some((name, child)) = children.remove(&entry.inode) else {
                        return Ok(None);
                    };
                    if name != fresh.name(slot) {
                        return Ok(None);
                    }
                    fresh.entries[slot].child = child;
                }
            }
            if !children.is_empty() {
                return Ok(None);
            }
            if fresh.own_bytes == old.own_bytes
                && fresh.entries.as_slice() == old.entries.as_slice()
                && fresh.names.as_slice() == old.names.as_slice()
                && fresh.dates.as_deref() == old.dates.as_deref()
            {
                continue;
            }
            let direct_bytes = |f: &Folder| {
                f.own_bytes
                    + f.entries
                        .iter()
                        .filter(|e| e.child == NONE)
                        .map(|e| e.bytes)
                        .sum::<u64>()
            };
            let bytes = i128::from(direct_bytes(&fresh)) - i128::from(direct_bytes(old));
            let count = fresh.entries.len() as i128 - old.entries.len() as i128;
            fresh.freeze();
            updates.push((id, fresh, bytes, count));
        }
        if updates.is_empty() {
            return Ok(Some(Cow::Borrowed(self)));
        }
        let mut next = self.clone();
        next.revision = Arc::new(());
        next.rebuilt_from = None;
        next.delta = Some((
            self.revision.clone(),
            updates.iter().map(|(id, ..)| *id).collect(),
        ));
        let mut reorder = HashSet::new();
        for (id, fresh, bytes, count) in updates {
            for (slot, e) in fresh
                .entries
                .iter()
                .enumerate()
                .filter(|(_, e)| e.child != NONE)
            {
                next.folders[e.child as usize].parent = Some(Key {
                    folder: id,
                    slot: slot as u32,
                });
            }
            let f = &mut next.folders[id as usize];
            f.entries = fresh.entries;
            f.dates = fresh.dates;
            f.names = fresh.names;
            f.own_bytes = fresh.own_bytes;
            reorder.insert(id);
            let mut current = id;
            loop {
                let f = &mut next.folders[current as usize];
                f.total = (i128::from(f.total) + bytes) as u64;
                f.count = (i128::from(f.count) + count) as u64;
                f.files = (i128::from(f.files) + count) as u64;
                let Some(parent) = f.parent else {
                    break;
                };
                current = parent.folder;
                if bytes != 0 {
                    reorder.insert(current);
                }
            }
        }
        for id in reorder {
            progress.check()?;
            next.order[id as usize] = next.build_order(id, usize::MAX).into();
        }
        Ok(Some(Cow::Owned(next)))
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
        let mut dirty_branches = HashSet::new();
        if let Some(r) = &reuse {
            for &id in r.relist.iter().chain(&r.descend) {
                let mut dir = id;
                while dirty_branches.insert(dir) {
                    let Some(parent) = r.scan.folders[dir as usize].parent else {
                        break;
                    };
                    dir = parent.folder;
                }
            }
        }
        let threads = threads.clamp(1, 64);
        let build = Build {
            file_kinds: index,
            feed: (index && reuse.is_none())
                .then(|| progress.workspace.open(&root, &meta))
                .flatten(),
            budget: scan_policy::ScanBudget::new(threads),
            folders: Mutex::new(vec![Folder::default()]),
            root_error: Mutex::default(),
            progress,
            device: meta.dev(),
            reuse,
            dirty_branches,
            changed_links: Mutex::default(),
        };
        let workers = ThreadPoolBuilder::new()
            .num_threads(threads)
            .start_handler(scan_policy::worker_priority())
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
        let previous = build.reuse.as_ref().map(|r| r.scan);
        let mut inventory = Self {
            root,
            device: meta.dev(),
            folders: build.folders.into_inner().unwrap().into(),
            revision: Arc::new(()),
            scan_id: build.feed.as_ref().map(|f| f.id.clone()),
            provisional: false,
            delta: None,
            rebuilt_from: previous.map(|p| p.revision.clone()),
            groups: Arc::default(),
            owners: Arc::default(),
            order: Vec::new().into(),
            dirty_order: Vec::new(),
            protected: Vec::new(),
            issues: 0,
            boundaries: 0,
        };
        let links = build.changed_links.into_inner().unwrap();
        if !links.is_empty() {
            for f in inventory.folders.iter_mut() {
                for slot in 0..f.entries.len() {
                    let e = &f.entries[slot];
                    if e.kind != EntryKind::Directory
                        && let Some(&bytes) = links.get(&e.inode)
                        && (e.flags & LINKED == 0 || e.bytes != bytes)
                    {
                        let e = &mut f.entries[slot];
                        e.flags |= LINKED;
                        e.bytes = bytes;
                    }
                }
            }
        }
        inventory.finish(progress)?;
        inventory.protected = trash::protected_folders(&inventory);
        if index {
            let mut order = vec![Arc::default(); inventory.folders.len()];
            workers.install(|| {
                order
                    .par_chunks_mut(128)
                    .enumerate()
                    .try_for_each(|(chunk, slots)| {
                        let _permit = build.budget.enter(progress)?;
                        for (offset, slot) in slots.iter_mut().enumerate() {
                            let id = chunk * 128 + offset;
                            *slot = previous
                                .and_then(|p| {
                                    let old = inventory.folders[id].shared_leaf(p)?;
                                    p.order.get(old as usize).cloned()
                                })
                                .unwrap_or_else(|| {
                                    inventory.build_order(id as u32, usize::MAX).into()
                                });
                        }
                        Ok::<_, io::Error>(())
                    })
            })?;
            inventory.folders.iter_mut().for_each(Folder::freeze);
            inventory.order = order.into();
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
            for slot in 0..f.entries.len() {
                let e = &f.entries[slot];
                if e.kind == EntryKind::Directory {
                    stack.push((e.child as usize, false));
                    continue;
                }
                if e.flags & LINKED != 0 {
                    let key = Key {
                        folder: dir as u32,
                        slot: slot as u32,
                    };
                    let group = Arc::get_mut(&mut self.groups)
                        .unwrap()
                        .entry(e.inode)
                        .or_insert_with(|| LinkGroup {
                            bytes: e.bytes,
                            owner: key,
                            members: Vec::new(),
                        });
                    group.members.push(key);
                    if group.owner != key && e.bytes != 0 {
                        f.entries[slot].bytes = 0;
                    }
                }
                f.files += 1;
                f.total += f.entries[slot].bytes;
            }
        }
        Arc::get_mut(&mut self.groups)
            .unwrap()
            .retain(|_, g| g.members.len() > 1);
        for (inode, group) in self.groups.iter() {
            Arc::get_mut(&mut self.owners).unwrap().insert(
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
        self.revision = Arc::new(());
        self.delta = None;
        self.rebuilt_from = None;
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
            Arc::make_mut(&mut self.owners)
                .remove(&(self.folders[old.folder as usize].pre, old.slot));
            if let Some(next) = g.members.iter().copied().find(|&k| self.live(k)) {
                let bytes = g.bytes;
                self.folders[next.folder as usize].entries[next.slot as usize].bytes = bytes;
                Arc::make_mut(&mut self.groups)
                    .get_mut(&inode)
                    .unwrap()
                    .owner = next;
                Arc::make_mut(&mut self.owners)
                    .insert((self.folders[next.folder as usize].pre, next.slot), inode);
                self.adjust(next.folder, bytes, 0, 0, true);
            } else {
                Arc::make_mut(&mut self.groups).remove(&inode);
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
            self.order[dir as usize] = self.build_order(dir, usize::MAX).into();
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
