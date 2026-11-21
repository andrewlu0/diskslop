use super::Model;
use crate::{Inventory, Key, NONE, Progress, bulk::FileDates};
use rayon::prelude::*;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Created,
    Modified,
    Accessed,
    Folder,
    TopFolder,
    Extension,
    Depth,
    Size,
    Name,
}
impl Mode {
    fn read(value: u8) -> Option<Self> {
        Some(match value {
            1 => Self::Created,
            2 => Self::Modified,
            3 => Self::Accessed,
            4 => Self::Folder,
            5 => Self::TopFolder,
            6 => Self::Extension,
            7 => Self::Depth,
            8 => Self::Size,
            9 => Self::Name,
            _ => return None,
        })
    }
    fn ordered(self) -> bool {
        !matches!(
            self,
            Self::Folder | Self::TopFolder | Self::Extension | Self::Name
        )
    }
    fn uniform_folder(self) -> bool {
        matches!(self, Self::Folder | Self::TopFolder | Self::Depth)
    }
    fn date_field(self) -> Option<usize> {
        match self {
            Self::Created => Some(0),
            Self::Modified => Some(1),
            Self::Accessed => Some(2),
            _ => None,
        }
    }
}

fn age(minutes: i32, now: i64) -> u32 {
    if minutes == FileDates::UNKNOWN {
        return 10;
    }
    let elapsed = now - i64::from(minutes);
    if elapsed < 0 {
        return 9;
    }
    match elapsed / 1440 {
        0 => 0,
        1..=6 => 1,
        7..=29 => 2,
        30..=89 => 3,
        90..=364 => 4,
        365..=1094 => 5,
        1095..=1824 => 6,
        1825..=3649 => 7,
        _ => 8,
    }
}
fn size_band(bytes: u64) -> u32 {
    if bytes == 0 {
        return 0;
    }
    let limits = [
        1_000_000,
        10_000_000,
        100_000_000,
        1_000_000_000,
        10_000_000_000,
        100_000_000_000,
        1_000_000_000_000,
    ];
    1 + limits.partition_point(|limit| *limit <= bytes) as u32
}
fn depth_band(depth: u32) -> u32 {
    match depth {
        0..=3 => depth,
        4..=7 => 4,
        8..=15 => 5,
        _ => 6,
    }
}
const SEED: u32 = 2166136261;
fn hash(seed: u32, bytes: &[u8]) -> u32 {
    bytes
        .iter()
        .fold(seed, |v, &b| (v ^ u32::from(b)).wrapping_mul(16777619))
}
fn name_label<'a>(raw: &'a [u8], extension: bool, buffer: &'a mut Vec<u8>) -> &'a [u8] {
    let text = if extension {
        Path::new(OsStr::from_bytes(raw))
            .extension()
            .map_or(&[][..], OsStrExt::as_bytes)
    } else {
        raw
    };
    if !text.is_ascii()
        && let Ok(s) = std::str::from_utf8(text)
    {
        let normalized: String = if extension {
            s.to_lowercase().nfc().collect()
        } else {
            s.nfc().collect()
        };
        *buffer = normalized.into_bytes();
        return buffer;
    }
    if extension && text.iter().any(u8::is_ascii_uppercase) {
        buffer.clear();
        buffer.extend(text.iter().map(u8::to_ascii_lowercase));
        return buffer;
    }
    text
}
fn relative_name(scan: &Inventory, mut dir: u32, root: u32) -> Vec<u8> {
    let mut parts = Vec::new();
    while dir != root {
        let Some(parent) = scan.folders[dir as usize].parent else {
            break;
        };
        parts.push(scan.name(parent));
        dir = parent.folder;
    }
    parts.reverse();
    parts.join(&b'/')
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
pub(super) struct GroupInfo {
    bytes: u64,
    files: u64,
    tag: u32,
    color: u32,
}
struct Row {
    info: GroupInfo,
    start: usize,
    len: usize,
}
#[derive(Default)]
enum Assignments {
    #[default]
    Empty,
    Shared(u32),
    Slots(Box<[u32]>),
}

pub(super) struct Groups {
    mode: Mode,
    folders: Vec<Assignments>,
    rows: Vec<Row>,
    text: Vec<u8>,
    max_files: u64,
    slot_bytes: usize,
}
impl Groups {
    fn add(&mut self, label: &[u8], tag: u32, color: u32) -> u32 {
        let group = self.rows.len() as u32;
        self.rows.push(Row {
            info: GroupInfo {
                tag,
                color,
                ..Default::default()
            },
            start: self.text.len(),
            len: label.len(),
        });
        self.text.extend_from_slice(label);
        group
    }
    fn bucket(&mut self, bins: &mut [u32], tag: u32) -> u32 {
        let group = &mut bins[tag as usize];
        if *group == NONE {
            *group = self.add(&[], tag, tag);
        }
        *group
    }
    fn label(&self, row: &Row) -> &[u8] {
        &self.text[row.start..row.start + row.len]
    }
    fn group(&self, key: Key) -> Option<u32> {
        match self.folders.get(key.folder as usize)? {
            Assignments::Empty => None,
            Assignments::Shared(g) => Some(*g),
            Assignments::Slots(slots) => slots
                .get(key.slot as usize)
                .copied()
                .filter(|&id| id != NONE),
        }
    }
    pub(super) fn group_color(&self, key: Key) -> (u32, u32) {
        self.group(key)
            .map_or((NONE, 0), |id| (id, self.rows[id as usize].info.color))
    }
    fn build(
        scan: &Inventory,
        root: u32,
        mode: Mode,
        now: i64,
        progress: &Progress,
    ) -> Option<Self> {
        let start = scan.folders.get(root as usize)?;
        let root_path = start.parent.map(|key| scan.path(key));
        let root_name = root_path
            .as_deref()
            .unwrap_or(&scan.root)
            .as_os_str()
            .as_bytes();
        let root_hash = hash(SEED, root_name);
        let prefix = if root_name.ends_with(b"/") {
            root_hash
        } else {
            hash(root_hash, b"/")
        };
        let mut result = Self {
            mode,
            folders: (0..scan.folders.len())
                .map(|_| Assignments::Empty)
                .collect(),
            rows: Vec::new(),
            text: Vec::new(),
            max_files: 0,
            slot_bytes: 0,
        };
        let mut bins = [NONE; 11];
        let mut directories = HashMap::new();
        let mut empty_branches = Vec::new();
        let mut names = HashMap::<Vec<u8>, u32>::new();
        let mut lower = Vec::new();
        let mut pending = vec![(root, root, 0u32)];
        while let Some((id, top, depth)) = pending.pop() {
            progress.check().ok()?;
            let index = id as usize;
            let folder = &scan.folders[index];
            let mut shared = None;
            let mut slots = if mode.uniform_folder() {
                Vec::new()
            } else {
                vec![NONE; folder.entries.len()]
            };
            for (i, &slot) in scan.order[index].iter().enumerate() {
                if i.is_multiple_of(4096) {
                    progress.check().ok()?
                }
                let entry = &folder.entries[slot as usize];
                if entry.child != NONE {
                    pending.push((
                        entry.child,
                        if id == root { entry.child } else { top },
                        depth + 1,
                    ));
                    continue;
                }
                let group = if let Some(g) = shared {
                    g
                } else {
                    match mode {
                        Mode::Folder | Mode::TopFolder => {
                            let dir = if mode == Mode::Folder { id } else { top };
                            *directories.entry(dir).or_insert_with(|| {
                                let path = relative_name(scan, dir, root);
                                let color = if path.is_empty() {
                                    root_hash
                                } else {
                                    hash(prefix, &path)
                                };
                                result.add(&path, 0, color)
                            })
                        }
                        Mode::Name | Mode::Extension => {
                            let raw = folder.name(slot as usize);
                            let label = name_label(raw, mode == Mode::Extension, &mut lower);
                            if let Some(&g) = names.get(label) {
                                g
                            } else {
                                let g = result.add(label, 0, hash(SEED, label));
                                names.insert(label.to_vec(), g);
                                g
                            }
                        }
                        _ => {
                            let bucket = match mode {
                                Mode::Depth => depth_band(depth),
                                Mode::Size => size_band(entry.bytes),
                                _ => {
                                    let field = mode.date_field().unwrap();
                                    let minute = folder
                                        .dates
                                        .as_ref()
                                        .map_or(FileDates::UNKNOWN, |d| d[slot as usize].0[field]);
                                    age(minute, now)
                                }
                            };
                            result.bucket(&mut bins, bucket)
                        }
                    }
                };
                if mode.uniform_folder() {
                    shared = Some(group)
                } else {
                    slots[slot as usize] = group
                }
                let info = &mut result.rows[group as usize].info;
                info.bytes = info.bytes.saturating_add(entry.bytes);
                info.files += 1;
                result.max_files = result.max_files.max(info.files);
            }
            result.slot_bytes += slots.len() * size_of::<u32>();
            if mode == Mode::TopFolder && shared.is_none() {
                empty_branches.push((index, top));
            }
            result.folders[index] = if let Some(g) = shared {
                Assignments::Shared(g)
            } else if mode == Mode::Depth && !scan.order[index].is_empty() {
                Assignments::Shared(result.bucket(&mut bins, depth_band(depth)))
            } else if slots.is_empty() {
                Assignments::Empty
            } else {
                Assignments::Slots(slots.into_boxed_slice())
            };
        }
        for (folder, top) in empty_branches {
            if let Some(&group) = directories.get(&top) {
                result.folders[folder] = Assignments::Shared(group);
            }
        }
        Some(result)
    }
}

#[unsafe(no_mangle)]
extern "C" fn dt_groups_new(
    m: &Model,
    root: u32,
    mode: u8,
    as_of: i64,
    progress: &Progress,
) -> *mut Groups {
    Mode::read(mode)
        .and_then(|mode| {
            Groups::build(
                &m.scan.read().unwrap(),
                root,
                mode,
                as_of.div_euclid(60),
                progress,
            )
        })
        .map_or(std::ptr::null_mut(), |v| Box::into_raw(Box::new(v)))
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_groups_free(ptr: *mut Groups) {
    unsafe { drop(Box::from_raw(ptr)) }
}
#[unsafe(no_mangle)]
extern "C" fn dt_groups_count(g: &Groups) -> usize {
    g.rows.len()
}
#[unsafe(no_mangle)]
extern "C" fn dt_groups_max_files(g: &Groups) -> u64 {
    g.max_files
}
#[unsafe(no_mangle)]
extern "C" fn dt_groups_memory(g: &Groups) -> usize {
    g.slot_bytes
        + g.text.capacity()
        + g.rows.capacity() * size_of::<Row>()
        + g.folders.capacity() * size_of::<Assignments>()
}
#[unsafe(no_mangle)]
extern "C" fn dt_group_at(g: &Groups, key: Key) -> u32 {
    g.group(key).unwrap_or(NONE)
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_group_find(
    g: &Groups,
    hint: u32,
    tag: u32,
    color: u32,
    label: *const u8,
    length: usize,
) -> u32 {
    let name = if length == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(label, length) }
    };
    let matches =
        |row: &Row| row.info.tag == tag && row.info.color == color && g.label(row) == name;
    if g.rows.get(hint as usize).is_some_and(matches) {
        return hint;
    }
    g.rows.iter().position(matches).map_or(NONE, |id| id as u32)
}
#[unsafe(no_mangle)]
extern "C" fn dt_group_directory(g: &Groups, dir: u32) -> u32 {
    match g.folders.get(dir as usize) {
        Some(Assignments::Shared(id)) => *id,
        _ => NONE,
    }
}
#[unsafe(no_mangle)]
extern "C" fn dt_group_date(m: &Model, key: Key, mode: u8, seconds: &mut i64) -> bool {
    let Some(field) = Mode::read(mode).and_then(Mode::date_field) else {
        return false;
    };
    let scan = m.scan.read().unwrap();
    let minute = scan
        .folders
        .get(key.folder as usize)
        .and_then(|f| f.dates.as_ref())
        .and_then(|d| d.get(key.slot as usize))
        .map(|d| d.0[field]);
    if let Some(value) = minute.filter(|&v| v != FileDates::UNKNOWN) {
        *seconds = i64::from(value) * 60;
        true
    } else {
        false
    }
}
#[unsafe(no_mangle)]
extern "C" fn dt_group_read(
    g: &Groups,
    id: u32,
    info: &mut GroupInfo,
    len: &mut usize,
) -> *const u8 {
    let Some(row) = g.rows.get(id as usize) else {
        *len = 0;
        return std::ptr::null();
    };
    *info = row.info;
    let label = g.label(row);
    *len = label.len();
    label.as_ptr()
}

struct GroupOrder {
    ids: Vec<u32>,
    ranks: Vec<u32>,
}
#[unsafe(no_mangle)]
extern "C" fn dt_groups_sorted(g: &Groups, column: u8, ascending: bool) -> *mut GroupOrder {
    let mut ids: Vec<_> = (0..g.rows.len() as u32).collect();
    let compare = |&a: &u32, &b: &u32| {
        let (a, b) = (&g.rows[a as usize], &g.rows[b as usize]);
        let by_group = || {
            if g.mode.ordered() {
                a.info.tag.cmp(&b.info.tag)
            } else {
                g.label(a).cmp(g.label(b))
            }
        };
        let order = match column {
            1 => a.info.files.cmp(&b.info.files),
            2 => a.info.bytes.cmp(&b.info.bytes),
            _ => by_group(),
        };
        if order == Ordering::Equal {
            by_group()
        } else if ascending {
            order
        } else {
            order.reverse()
        }
    };
    if ids.len() >= 32_768 {
        ids.par_sort_unstable_by(compare)
    } else {
        ids.sort_unstable_by(compare)
    }
    let mut ranks = vec![0; ids.len()];
    for (i, &id) in ids.iter().enumerate() {
        ranks[id as usize] = i as u32
    }
    Box::into_raw(Box::new(GroupOrder { ids, ranks }))
}
#[unsafe(no_mangle)]
extern "C" fn dt_order_group(o: &GroupOrder, index: usize) -> u32 {
    o.ids.get(index).copied().unwrap_or(NONE)
}
#[unsafe(no_mangle)]
extern "C" fn dt_order_rank(o: &GroupOrder, id: u32) -> u32 {
    o.ranks.get(id as usize).copied().unwrap_or(NONE)
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_order_free(ptr: *mut GroupOrder) {
    unsafe { drop(Box::from_raw(ptr)) }
}
