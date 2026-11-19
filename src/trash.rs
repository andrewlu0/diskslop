use super::*;

#[derive(Clone, Copy)]
pub(crate) struct ProtectedFolder {
    id: usize,
    kind: u8,
}

impl ProtectedFolder {
    fn label(self) -> &'static str {
        if self.kind == 1 {
            "volume"
        } else {
            "home folder"
        }
    }
}

fn is_volume_root(scan: &Inventory) -> bool {
    if scan.root.parent().is_none() {
        return true;
    }
    let Ok(path) = bulk::checked_name(scan.root.as_os_str().as_bytes()) else {
        return true;
    };
    let mut result = std::mem::MaybeUninit::<libc::statfs>::uninit();
    if unsafe { libc::statfs(path.as_ptr(), result.as_mut_ptr()) } != 0 {
        return true;
    }
    let mount = unsafe { result.assume_init() };
    let name = unsafe { CStr::from_ptr(mount.f_mntonname.as_ptr()) };
    fs::metadata(OsStr::from_bytes(name.to_bytes()))
        .map(|m| (m.dev(), m.ino()) == (scan.device, scan.folders[0].inode))
        .unwrap_or(true)
}

pub(crate) fn protected_folders(scan: &Inventory) -> Vec<ProtectedFolder> {
    let mut scopes = Vec::new();
    if is_volume_root(scan) {
        scopes.push(ProtectedFolder { id: 0, kind: 1 });
    }
    if let Some(home) = std::env::home_dir().and_then(|p| fs::metadata(p).ok())
        && home.dev() == scan.device
        && let Some(id) = scan.folders.iter().position(|f| f.inode == home.ino())
        && !scopes.iter().any(|s| s.id == id)
    {
        scopes.push(ProtectedFolder { id, kind: 2 });
    }
    scopes
}

#[repr(C)]
#[derive(Clone, Copy, Default, Eq, PartialEq)]
pub(crate) struct TrashImpact {
    pub bytes: u64,
    pub files: u64,
    pub folders: u64,
    pub scope: u8,
    pub percent: u8,
}

#[derive(PartialEq, Eq)]
pub(crate) struct Review {
    pub roots: Vec<Key>,
    pub impact: TrashImpact,
}

impl Review {
    pub fn require_acknowledgment(&self, acknowledged: bool) -> io::Result<()> {
        if self.impact.scope != 0 && !acknowledged {
            return Err(io::Error::other(
                "Review the size of this selection before moving it to Trash.",
            ));
        }
        Ok(())
    }
}

impl Inventory {
    fn contains_dir(&self, outer: usize, inner: usize) -> bool {
        let outer = &self.folders[outer];
        (outer.pre..outer.end).contains(&self.folders[inner].pre)
    }

    pub(crate) fn review_trash(&self, keys: &[Key]) -> io::Result<Review> {
        if keys.is_empty() {
            return Err(io::Error::other("Select an item to move to Trash."));
        }
        if self
            .root
            .components()
            .any(|c| matches!(c.as_os_str().as_bytes(), b".Trash" | b".Trashes"))
        {
            return Err(io::Error::other("This location is already in the Trash."));
        }
        let mut unique = HashSet::with_capacity(keys.len());
        let mut roots = Vec::with_capacity(keys.len());
        for &key in keys {
            if key.slot == NONE {
                return Err(io::Error::other("The scan root is protected."));
            }
            if !self.live(key) {
                return Err(io::Error::other("The selection changed. Review it again."));
            }
            if unique.insert(key) {
                roots.push(key);
            }
        }
        if roots.len() > 1 {
            roots.retain(|key| {
                let mut folder = key.folder;
                while let Some(parent) = self.folders[folder as usize].parent {
                    if unique.contains(&parent) {
                        return false;
                    }
                    folder = parent.folder;
                }
                true
            });
        }
        let mut impact = TrashImpact::default();
        let mut scoped = vec![TrashImpact::default(); self.protected.len()];
        for &key in &roots {
            let entry = self.entry(key);
            let bytes = self.size(key);
            let (files, folders) = if entry.child == NONE {
                (1, 0)
            } else {
                let child = &self.folders[entry.child as usize];
                if child.contains_mount {
                    return Err(io::Error::other(
                        "A selected folder contains another mounted volume. Choose items inside that folder.",
                    ));
                }
                (child.files, child.count - child.files + 1)
            };
            impact.files += files;
            impact.folders += folders;
            impact.bytes = impact.bytes.saturating_add(bytes);
            for (scope, part) in self.protected.iter().zip(&mut scoped) {
                if entry.child != NONE && self.contains_dir(entry.child as usize, scope.id) {
                    return Err(io::Error::other(format!(
                        "This selection includes the entire {}. Choose items inside it.",
                        scope.label()
                    )));
                }
                if self.contains_dir(scope.id, key.folder as usize) {
                    part.files += files;
                    part.folders += folders;
                    part.bytes = part.bytes.saturating_add(bytes);
                }
            }
        }
        for (scope, part) in self.protected.iter().zip(scoped) {
            let f = &self.folders[scope.id];
            if f.count > 0 && part.files + part.folders == f.count {
                return Err(io::Error::other(format!(
                    "This selection includes everything scanned in this {}. Choose fewer items.",
                    scope.label()
                )));
            }
            if f.files > 0 && part.files == f.files {
                return Err(io::Error::other(format!(
                    "This selection includes every scanned file in this {}. Choose fewer files.",
                    scope.label()
                )));
            }
            if f.total > 0 && part.bytes > 0 && u128::from(part.bytes) * 2 >= u128::from(f.total) {
                let share = (u128::from(part.bytes) * 100 / u128::from(f.total)).min(100) as u8;
                if share >= impact.percent {
                    impact.scope = scope.kind;
                    impact.percent = share;
                }
            }
        }
        Ok(Review { roots, impact })
    }
}
