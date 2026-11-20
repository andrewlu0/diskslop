use super::*;

#[derive(Default)]
pub(super) struct Subscription {
    enabled: AtomicBool,
    feed: Mutex<Option<Arc<Feed>>>,
}

impl Subscription {
    pub(super) fn enable(&self) {
        self.enabled.store(true, Ordering::Relaxed);
    }

    pub(super) fn open(&self, root: &Path, meta: &fs::Metadata) -> Option<Arc<Feed>> {
        if !self.enabled.load(Ordering::Relaxed) {
            return None;
        }
        let id = Arc::new(());
        let inventory = Inventory {
            root: root.to_owned(),
            device: meta.dev(),
            folders: vec![Folder {
                inode: meta.ino(),
                ..Default::default()
            }]
            .into(),
            order: vec![Arc::default()].into(),
            revision: Arc::new(()),
            scan_id: Some(id.clone()),
            provisional: true,
            delta: None,
            rebuilt_from: None,
            groups: Arc::default(),
            owners: Arc::default(),
            dirty_order: Vec::new(),
            protected: Vec::new(),
            issues: 0,
            boundaries: 0,
        };
        let feed = Arc::new(Feed {
            id,
            epoch: AtomicU64::new(1),
            pending: Mutex::default(),
            reader: Mutex::new(Reader {
                inventory,
                owners: HashMap::new(),
            }),
        });
        *self.feed.lock().unwrap() = Some(feed.clone());
        Some(feed)
    }

    pub(super) fn next(&self, progress: &Progress) -> Option<Inventory> {
        let feed = self.feed.lock().unwrap().clone()?;
        let mut reader = feed.reader.lock().unwrap();
        let pending = std::mem::take(&mut *feed.pending.lock().unwrap());
        feed.epoch.fetch_add(1, Ordering::Relaxed);
        if pending.is_empty() {
            return None;
        }
        reader.apply(pending, progress)
    }

    pub(super) fn close(&self) {
        self.enabled.store(false, Ordering::Relaxed);
        let retired = self.feed.lock().unwrap().take();
        drop(retired);
    }
}

pub(super) struct Feed {
    pub(super) id: Arc<()>,
    pub(super) epoch: AtomicU64,
    pending: Mutex<HashMap<u32, Folder>>,
    reader: Mutex<Reader>,
}

impl Feed {
    pub(super) fn publish(&self, id: u32, folder: Folder) {
        self.pending.lock().unwrap().insert(id, folder);
    }
}

struct Reader {
    inventory: Inventory,
    owners: HashMap<u64, Key>,
}

impl Reader {
    fn apply(&mut self, pending: HashMap<u32, Folder>, progress: &Progress) -> Option<Inventory> {
        let scan = &mut self.inventory;
        let mut dirty = HashSet::new();
        let mut updates: Vec<_> = pending.into_iter().collect();
        // Parents reserve identifiers before scheduling their children.
        updates.sort_unstable_by_key(|(id, _)| *id);
        for (id, mut folder) in updates {
            progress.check().ok()?;
            let index = id as usize;
            folder.parent = scan.folders[index].parent;
            let old = &scan.folders[index];
            scan.issues = scan.issues - old.issues + folder.issues;
            scan.boundaries = scan.boundaries - old.boundaries + folder.boundaries;
            for slot in 0..folder.entries.len() {
                let entry = &folder.entries[slot];
                let key = Key {
                    folder: id,
                    slot: slot as u32,
                };
                if entry.child != NONE {
                    let child = entry.child as usize;
                    if child >= scan.folders.len() {
                        scan.folders.grow(child + 1, Folder::default());
                    }
                    if scan.folders[child].parent.is_none() {
                        scan.folders[child].parent = Some(key);
                        scan.folders[child].inode = entry.inode;
                        dirty.insert(entry.child);
                    }
                } else if entry.flags & LINKED != 0
                    && entry.bytes != 0
                    && *self.owners.entry(entry.inode).or_insert(key) != key
                {
                    folder.entries[slot].bytes = 0;
                }
            }
            folder.freeze();
            scan.folders[index] = folder;
            dirty.insert(id);
            let mut parent = scan.folders[index].parent;
            while let Some(key) = parent {
                if !dirty.insert(key.folder) {
                    break;
                }
                parent = scan.folders[key.folder as usize].parent;
            }
        }
        scan.order.grow(scan.folders.len(), Arc::default());
        let mut dirty: Vec<_> = dirty.into_iter().collect();
        dirty.sort_unstable();
        for &id in dirty.iter().rev() {
            progress.check().ok()?;
            let i = id as usize;
            let f = &scan.folders[i];
            let (mut total, mut count, mut files) = (f.own_bytes, f.entries.len() as u64, 0);
            for e in f.entries.iter() {
                if e.child == NONE {
                    total += e.bytes;
                    files += 1;
                } else {
                    let child = &scan.folders[e.child as usize];
                    total += child.total;
                    count += child.count;
                    files += child.files;
                }
            }
            let folder = &mut scan.folders[i];
            (folder.total, folder.count, folder.files) = (total, count, files);
            if count != 0 {
                scan.order[i] = scan.build_order(id, usize::MAX).into();
            }
        }
        let prior = std::mem::replace(&mut scan.revision, Arc::new(()));
        scan.delta = Some((prior, dirty));
        Some(scan.clone())
    }
}
