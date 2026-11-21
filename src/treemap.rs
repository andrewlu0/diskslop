use super::{Folder, Inventory, Key, Model, NONE};
#[path = "color_groups.rs"]
mod color_groups;
use color_groups::Groups;
#[path = "file_kinds.rs"]
mod file_kinds;
use crate::pages::Pages;
use file_kinds::{KindTotal, Resolve, Resolver};
use std::collections::{HashMap, HashSet};
use std::mem::size_of;
use std::sync::{Arc, OnceLock};

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl Rect {
    const UNIT: Self = Self {
        x: 0.0,
        y: 0.0,
        w: 1.0,
        h: 1.0,
    };
    fn inside(self, parent: Self) -> Self {
        Self {
            x: parent.x + self.x * parent.w,
            y: parent.y + self.y * parent.h,
            w: self.w * parent.w,
            h: self.h * parent.h,
        }
    }
    fn intersects(self, b: Self) -> bool {
        self.x < b.x + b.w && self.y < b.y + b.h && self.x + self.w > b.x && self.y + self.h > b.y
    }
    fn contains(self, x: f64, y: f64) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w && y < self.y + self.h
    }
    fn union(self, b: Self) -> Self {
        let (x, y) = (self.x.min(b.x), self.y.min(b.y));
        Self {
            x,
            y,
            w: (self.x + self.w).max(b.x + b.w) - x,
            h: (self.y + self.h).max(b.y + b.h) - y,
        }
    }
}

#[derive(Clone, Copy)]
struct Mark {
    slot: u32,
    child: u32,
    kind: u32,
}
#[derive(Default)]
struct Layout {
    bounds: Vec<Rect>,
    order: Vec<Mark>,
    bands: Vec<Rect>,
}
impl Layout {
    fn storage(&self) -> usize {
        size_of::<Self>()
            + (self.bounds.capacity() + self.bands.capacity()) * size_of::<Rect>()
            + self.order.capacity() * size_of::<Mark>()
    }
}
#[derive(Default)]
struct Sheet {
    layout: OnceLock<Box<Layout>>,
    kinds: Vec<u32>,
    enclosing_kind: u32,
    mass: u64,
}
impl Sheet {
    fn kind(&self, slot: u32) -> u32 {
        if self.enclosing_kind != 0 {
            self.enclosing_kind
        } else {
            self.kinds.get(slot as usize).copied().unwrap_or(0)
        }
    }
}
#[derive(Clone, Default)]
struct Placement {
    parent: Option<Key>,
    sheet: Option<Arc<Sheet>>,
}
struct Scene {
    folders: Pages<Folder>,
    order: Pages<Arc<[u32]>>,
    sheets: Pages<Placement>,
    revision: Arc<()>,
    aspect: f64,
    root: u32,
    files: usize,
    totals: Vec<KindTotal>,
}

const GROUP: usize = 32;
struct Weighted {
    mark: Mark,
    weight: f64,
}

fn worst(low: f64, high: f64, sum: f64, side_squared: f64) -> f64 {
    let factor = side_squared / (sum * sum);
    (high * factor).max(1.0 / (low * factor))
}

// Greedily finish a strip when the next rectangle would worsen its longest aspect ratio.
fn squarify(items: &[Weighted], total: f64, mut rect: Rect, mut emit: impl FnMut(Mark, Rect)) {
    let mut start = 0;
    let mut remaining = total;
    while start < items.len() && remaining > 0.0 {
        let vertical = rect.w >= rect.h;
        let side = if vertical { rect.h } else { rect.w };
        if side <= 0.0 {
            return;
        }
        let side_squared = side * side * remaining / (rect.w * rect.h);
        let high = items[start].weight;
        let mut sum = high;
        let mut end = start + 1;
        let mut score = worst(high, high, high, side_squared);
        while end < items.len() {
            let next = items[end].weight;
            let candidate = worst(next, high, sum + next, side_squared);
            if candidate > score {
                break;
            }
            score = candidate;
            sum += next;
            end += 1;
        }
        let long = if vertical { rect.w } else { rect.h };
        let width = if end == items.len() {
            long
        } else {
            long * (sum / remaining).min(1.0)
        };
        let mut offset = 0.0;
        for (i, item) in items[start..end].iter().enumerate() {
            let length = if i + start + 1 == end {
                side - offset
            } else {
                (side * item.weight / sum).min(side - offset)
            };
            let cell = if vertical {
                Rect {
                    x: rect.x,
                    y: rect.y + offset,
                    w: width,
                    h: length,
                }
            } else {
                Rect {
                    x: rect.x + offset,
                    y: rect.y,
                    w: length,
                    h: width,
                }
            };
            emit(item.mark, cell);
            offset += length;
        }
        if vertical {
            rect.x += width;
            rect.w -= width;
        } else {
            rect.y += width;
            rect.h -= width;
        }
        remaining -= sum;
        start = end;
    }
}

impl Sheet {
    fn classify(
        scan: &Inventory,
        folder: u32,
        enclosing_kind: u32,
        resolver: &mut Resolver,
    ) -> Self {
        let id = folder as usize;
        let mut sheet = Self {
            enclosing_kind,
            ..Default::default()
        };
        if enclosing_kind == 0 {
            sheet.kinds.resize(scan.folders[id].entries.len(), 0);
            for &slot in scan.order[id].iter() {
                sheet.kinds[slot as usize] = resolver.kind(scan, Key { folder, slot });
            }
        }
        sheet
    }

    fn count_kinds(
        &self,
        scan: &Inventory,
        folder: u32,
        totals: &mut HashMap<u32, KindTotal>,
        add: bool,
    ) {
        if self.enclosing_kind != 0 {
            return;
        }
        for &slot in scan.order[folder as usize].iter() {
            let kind = self.kind(slot);
            if kind == 0 {
                continue;
            }
            let value = totals.entry(kind).or_insert(KindTotal {
                kind,
                ..Default::default()
            });
            let bytes = scan.size(Key { folder, slot });
            if add {
                value.files += 1;
                value.bytes += bytes;
            } else {
                value.files -= 1;
                value.bytes -= bytes;
            }
        }
    }

    fn build_layout(
        &self,
        folder: &Folder,
        order: &[u32],
        aspect: f64,
        child_mass: impl Fn(u32) -> u64,
        weighted: &mut Vec<Weighted>,
    ) -> Box<Layout> {
        let mut layout = Layout::default();
        weighted.clear();
        for &slot in order {
            let entry = &folder.entries[slot as usize];
            let weight = if entry.child == NONE {
                entry.bytes.max(1)
            } else {
                child_mass(entry.child)
            };
            if weight > 0 {
                weighted.push(Weighted {
                    mark: Mark {
                        slot,
                        child: entry.child,
                        kind: self.kind(slot),
                    },
                    weight: weight as f64,
                });
            }
        }
        if !weighted.windows(2).all(|w| w[0].weight >= w[1].weight) {
            weighted.sort_by(|a, b| b.weight.total_cmp(&a.weight));
        }
        layout.bounds.resize(folder.entries.len(), Rect::default());
        layout.order.reserve_exact(weighted.len());
        let aspect = aspect.clamp(1e-12, 1e12);
        squarify(
            weighted,
            self.mass as f64,
            Rect {
                w: aspect,
                ..Rect::UNIT
            },
            |mark, cell| {
                let local = Rect {
                    x: cell.x / aspect,
                    w: cell.w / aspect,
                    ..cell
                };
                layout.bounds[mark.slot as usize] = local;
                if layout.order.len().is_multiple_of(GROUP) {
                    layout.bands.push(local)
                } else if let Some(last) = layout.bands.last_mut() {
                    *last = last.union(local)
                }
                layout.order.push(mark);
            },
        );
        Box::new(layout)
    }
}

impl Scene {
    fn new(m: &Model, root: u32, aspect: f64, resolve: Resolve) -> Self {
        let scan = m.scan.read().unwrap();
        Self::build(&scan, root, aspect, resolve, None)
    }

    fn build(
        scan: &Inventory,
        root: u32,
        aspect: f64,
        resolve: Resolve,
        previous: Option<(&Self, &Inventory)>,
    ) -> Self {
        let aspect = aspect.clamp(0.05, 32.0);
        let mut sheets: Vec<Option<Arc<Sheet>>> = vec![None; scan.folders.len()];
        let mut mass = vec![0u64; sheets.len()];
        let mut folders = vec![(root, 0)];
        let mut resolver = Resolver::new(resolve);
        let mut totals: HashMap<_, _> = previous
            .map(|(scene, _)| scene.totals.iter().map(|t| (t.kind, *t)).collect())
            .unwrap_or_default();
        let mut kept = previous
            .map(|(scene, _)| vec![false; scene.sheets.len()])
            .unwrap_or_default();
        let mut index = 0;
        while index < folders.len() {
            let (folder, enclosing) = folders[index];
            let id = folder as usize;
            if let Some((scene, old)) = previous
                && let Some(prior) = scan.folders[id].shared_leaf(old)
                && let Some(sheet) = scene.sheets[prior as usize].sheet.as_ref()
                && sheet.enclosing_kind == enclosing
            {
                mass[id] = sheet.mass;
                sheets[id] = Some(sheet.clone());
                kept[prior as usize] = true;
                index += 1;
                continue;
            }
            let sheet = Sheet::classify(scan, folder, enclosing, &mut resolver);
            sheet.count_kinds(scan, folder, &mut totals, true);
            for &slot in scan.order[id].iter() {
                let entry = &scan.folders[id].entries[slot as usize];
                if entry.child == NONE {
                    mass[id] = mass[id].saturating_add(entry.bytes.max(1))
                } else {
                    folders.push((entry.child, sheet.kind(slot)))
                }
            }
            sheets[id] = Some(Arc::new(sheet));
            index += 1;
        }
        if let Some((scene, old)) = previous {
            for (id, picked) in kept.into_iter().enumerate() {
                if !picked && let Some(sheet) = scene.sheet(id as u32) {
                    sheet.count_kinds(old, id as u32, &mut totals, false);
                }
            }
        }
        for &(folder, _) in folders.iter().skip(1).rev() {
            let id = folder as usize;
            let parent = scan.folders[id].parent.unwrap().folder as usize;
            mass[parent] = mass[parent].saturating_add(mass[id]);
        }
        let placed: Vec<_> = sheets
            .into_iter()
            .enumerate()
            .map(|(id, sheet)| {
                if let Some(mut sheet) = sheet {
                    if let Some(sheet) = Arc::get_mut(&mut sheet) {
                        sheet.mass = mass[id]
                    }
                    Placement {
                        parent: scan.folders[id].parent,
                        sheet: Some(sheet),
                    }
                } else {
                    Placement::default()
                }
            })
            .collect();
        Self {
            folders: scan.folders.clone(),
            order: scan.order.clone(),
            sheets: placed.into(),
            root,
            files: scan.folders[root as usize].files as usize,
            aspect,
            revision: scan.revision.clone(),
            totals: totals.into_values().filter(|t| t.files != 0).collect(),
        }
    }

    fn sheet(&self, folder: u32) -> Option<&Sheet> {
        self.sheets.get(folder as usize)?.sheet.as_deref()
    }

    fn layout(&self, folder: u32, parent: Rect, scratch: &mut Vec<Weighted>) -> Option<&Layout> {
        if parent.w <= 0.0 || parent.h <= 0.0 {
            return None;
        }
        let sheet = self.sheet(folder)?;
        let id = folder as usize;
        Some(sheet.layout.get_or_init(|| {
            sheet.build_layout(
                &self.folders[id],
                &self.order[id],
                self.aspect * parent.w / parent.h,
                |child| self.sheet(child).map_or(0, |s| s.mass),
                scratch,
            )
        }))
    }

    fn bounds(&self, mut key: Key) -> Option<Rect> {
        let mut path = vec![key];
        while key.folder != self.root {
            key = self.sheets.get(key.folder as usize)?.parent?;
            path.push(key);
        }
        let mut rect = Rect::UNIT;
        let mut scratch = Vec::new();
        for key in path.into_iter().rev() {
            rect = self
                .layout(key.folder, rect, &mut scratch)?
                .bounds
                .get(key.slot as usize)?
                .inside(rect);
            if rect.w <= 0.0 || rect.h <= 0.0 {
                return None;
            }
        }
        Some(rect)
    }

    fn refreshed(
        &self,
        prior: &Model,
        next: &Model,
        root: u32,
        aspect: f64,
        resolve: Resolve,
    ) -> Option<Self> {
        if std::ptr::eq(prior, next) || (aspect / self.aspect).ln().abs() > 0.20 {
            return None;
        }
        let new = next.scan.read().unwrap();
        let old = prior.scan.read().unwrap();
        let completing = old.provisional
            && !new.provisional
            && root == self.root
            && old
                .scan_id
                .as_ref()
                .zip(new.scan_id.as_ref())
                .is_some_and(|(a, b)| Arc::ptr_eq(a, b));
        if (completing
            || new
                .rebuilt_from
                .as_ref()
                .is_some_and(|base| Arc::ptr_eq(base, &self.revision)))
            && Arc::ptr_eq(&old.revision, &self.revision)
            && old.folders[self.root as usize].inode == new.folders[root as usize].inode
        {
            return Some(Self::build(&new, root, aspect, resolve, Some((self, &old))));
        }
        if root != self.root {
            return None;
        }
        let (base, dirty) = new.delta.as_ref()?;
        if !Arc::ptr_eq(base, &self.revision) {
            return None;
        }
        if !Arc::ptr_eq(&old.revision, base) {
            return None;
        }
        let scope = &new.folders[root as usize];
        let ordered = if new.provisional && root == 0 {
            dirty.clone()
        } else {
            if new.provisional {
                return None;
            }
            let mut affected = HashSet::new();
            for &id in dirty {
                if !(scope.pre..scope.end).contains(&new.folders[id as usize].pre) {
                    continue;
                }
                let mut dir = id;
                while affected.insert(dir) && dir != root {
                    dir = new.folders[dir as usize].parent?.folder;
                }
            }
            let mut ordered: Vec<_> = affected.into_iter().collect();
            ordered.sort_unstable_by_key(|&id| new.folders[id as usize].pre);
            ordered
        };
        let mut scene = Self {
            folders: new.folders.clone(),
            order: new.order.clone(),
            sheets: self.sheets.clone(),
            root,
            files: scope.files as usize,
            revision: new.revision.clone(),
            aspect,
            totals: Vec::new(),
        };
        scene.sheets.grow(new.folders.len(), Placement::default());
        let mut totals: HashMap<_, _> = self.totals.iter().map(|t| (t.kind, *t)).collect();
        let mut masses = HashMap::new();
        let mut replacements = HashMap::<u32, Sheet>::new();
        let mut resolver = Resolver::new(resolve);
        for &folder in &ordered {
            let id = folder as usize;
            let parent = new.folders[id].parent;
            let enclosing = if folder == root {
                0
            } else {
                let p = parent?;
                replacements
                    .get(&p.folder)
                    .or_else(|| self.sheet(p.folder))?
                    .kind(p.slot)
            };
            if let Some(previous) = self.sheet(folder) {
                previous.count_kinds(&old, folder, &mut totals, false);
            }
            if scene.sheets[id].parent != parent {
                scene.sheets[id].parent = parent;
            }
            let sheet = Sheet::classify(&new, folder, enclosing, &mut resolver);
            sheet.count_kinds(&new, folder, &mut totals, true);
            replacements.insert(folder, sheet);
        }
        for &folder in ordered.iter().rev() {
            let id = folder as usize;
            let sheet = replacements.get_mut(&folder)?;
            for &slot in new.order[id].iter() {
                let entry = &new.folders[id].entries[slot as usize];
                let weight = if entry.child == NONE {
                    entry.bytes.max(1)
                } else {
                    let parent = Some(Key { folder, slot });
                    if scene.sheets[entry.child as usize].parent != parent {
                        scene.sheets[entry.child as usize].parent = parent;
                    }
                    if let Some(&mass) = masses.get(&entry.child) {
                        mass
                    } else {
                        let child = self.sheet(entry.child)?;
                        if child.enclosing_kind != sheet.kind(slot) {
                            return None;
                        }
                        child.mass
                    }
                };
                sheet.mass = sheet.mass.saturating_add(weight);
            }
            masses.insert(folder, sheet.mass);
        }
        for (folder, sheet) in replacements {
            scene.sheets[folder as usize].sheet = Some(Arc::new(sheet));
        }
        scene.totals = totals.into_values().filter(|t| t.files != 0).collect();
        Some(scene)
    }

    fn walk(
        &self,
        intersects: impl Fn(Rect) -> bool,
        descend: impl Fn(Rect) -> bool,
        mut visit: impl FnMut(Key, Rect, u32) -> bool,
    ) {
        let mut pending = vec![(self.root, Rect::UNIT)];
        let mut scratch = Vec::new();
        while let Some((folder, parent)) = pending.pop() {
            let Some(sheet) = self.layout(folder, parent, &mut scratch) else {
                continue;
            };
            for (band, marks) in sheet.bands.iter().zip(sheet.order.chunks(GROUP)) {
                if !intersects(band.inside(parent)) {
                    continue;
                }
                for mark in marks {
                    let r = sheet.bounds[mark.slot as usize].inside(parent);
                    if !intersects(r) {
                        continue;
                    }
                    if mark.child != NONE && descend(r) {
                        pending.push((mark.child, r));
                    } else if visit(
                        Key {
                            folder,
                            slot: mark.slot,
                        },
                        r,
                        mark.kind,
                    ) {
                        return;
                    }
                }
            }
        }
    }
}

#[unsafe(no_mangle)]
extern "C" fn dt_map_new(m: &Model, root: u32, aspect: f64, resolve: Resolve) -> *mut Scene {
    Box::into_raw(Box::new(Scene::new(m, root, aspect, resolve)))
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_refresh(
    scene: &Scene,
    prior: &Model,
    next: &Model,
    root: u32,
    aspect: f64,
    resolve: Resolve,
) -> *mut Scene {
    scene
        .refreshed(prior, next, root, aspect, resolve)
        .map_or(std::ptr::null_mut(), |s| Box::into_raw(Box::new(s)))
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_map_free(s: *mut Scene) {
    unsafe {
        drop(Box::from_raw(s));
    }
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_kinds(s: &Scene, count: &mut usize) -> *const KindTotal {
    *count = s.totals.len();
    s.totals.as_ptr()
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_kind(s: &Scene, key: Key) -> u32 {
    s.sheet(key.folder).map_or(0, |sheet| sheet.kind(key.slot))
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_count(s: &Scene) -> usize {
    s.files
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_memory(s: &Scene) -> usize {
    s.sheets.len() * size_of::<Placement>()
        + s.sheets
            .iter()
            .filter_map(|p| p.sheet.as_ref())
            .map(|sheet| {
                size_of::<Sheet>()
                    + sheet.kinds.capacity() * size_of::<u32>()
                    + sheet.layout.get().map_or(0, |layout| layout.storage())
            })
            .sum::<usize>()
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_bounds(s: &Scene, key: Key, out: &mut Rect) -> bool {
    if let Some(rect) = s.bounds(key) {
        *out = rect;
        true
    } else {
        false
    }
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_hit(s: &Scene, x: f64, y: f64, out: &mut Key) -> bool {
    let mut hit = false;
    s.walk(
        |r| r.contains(x, y),
        |_| true,
        |key, _, _| {
            *out = key;
            hit = true;
            true
        },
    );
    hit
}
struct Selection(Vec<Key>);
#[unsafe(no_mangle)]
extern "C" fn dt_map_selection(s: &Scene, area: Rect) -> *mut Selection {
    let mut items = Vec::new();
    s.walk(
        |r| r.intersects(area),
        |_| true,
        |key, _, _| {
            items.push(key);
            false
        },
    );
    Box::into_raw(Box::new(Selection(items)))
}
#[unsafe(no_mangle)]
extern "C" fn dt_selection_keys(s: &Selection, count: &mut usize) -> *const Key {
    *count = s.0.len();
    s.0.as_ptr()
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_selection_free(s: *mut Selection) {
    unsafe {
        drop(Box::from_raw(s));
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Label {
    rect: Rect,
    key: Key,
    light_ink: bool,
}
struct Frame {
    pixels: Vec<u32>,
    labels: Vec<Label>,
}

fn pixel(rgb: u32, light: i32) -> u32 {
    let channel = |shift: u32| {
        let c = ((rgb >> shift) & 255) as i32;
        let delta = if light < 0 {
            c * light
        } else {
            (255 - c) * light
        };
        (c + delta / 255) as u32
    };
    channel(16) | channel(8) << 8 | channel(0) << 16 | 0xff000000
}

#[repr(C)]
struct GlassTint {
    surface: [u32; 129],
    top: u32,
    bottom: u32,
    seam: u32,
    light_ink: bool,
}
impl GlassTint {
    fn new(rgb: u32) -> Self {
        let surface = std::array::from_fn(|i| {
            let light = match i as i32 {
                t @ 0..=54 => (54 - t) * (54 - t) * 54 / 2916,
                55..=73 => 0,
                t @ 74..=102 => -(t - 73) * 12 / 29,
                t => -12 + (t - 102) * 29 / 26,
            };
            pixel(rgb, light)
        });
        let linear = |shift: u32| {
            let value = ((surface[24] >> shift) & 255) as f64 / 255.0;
            if value <= 0.04045 {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).powf(2.4)
            }
        };
        let luminance = 0.2126 * linear(0) + 0.7152 * linear(8) + 0.0722 * linear(16);
        Self {
            surface,
            top: pixel(rgb, 88),
            bottom: pixel(rgb, 44),
            seam: pixel(rgb, -38),
            light_ink: luminance < 0.179,
        }
    }
}

#[unsafe(no_mangle)]
extern "C" fn dt_glass_tint(rgb: u32) -> GlassTint {
    GlassTint::new(rgb)
}

#[unsafe(no_mangle)]
extern "C" fn dt_map_render(
    s: &Scene,
    port: Rect,
    width: u32,
    height: u32,
    scale: f64,
    palette: *const GlassTint,
    color_count: usize,
    shine: bool,
) -> *mut Frame {
    dt_map_render_groups(
        s,
        port,
        width,
        height,
        scale,
        palette,
        color_count,
        shine,
        None,
    )
}

#[unsafe(no_mangle)]
extern "C" fn dt_map_render_groups(
    s: &Scene,
    port: Rect,
    width: u32,
    height: u32,
    scale: f64,
    palette: *const GlassTint,
    color_count: usize,
    shine: bool,
    groups: Option<&Groups>,
) -> *mut Frame {
    dt_map_render_focused(
        s,
        port,
        width,
        height,
        scale,
        palette,
        color_count,
        shine,
        groups,
        NONE,
    )
}

#[unsafe(no_mangle)]
extern "C" fn dt_map_render_focused(
    s: &Scene,
    port: Rect,
    width: u32,
    height: u32,
    scale: f64,
    palette: *const GlassTint,
    color_count: usize,
    shine: bool,
    groups: Option<&Groups>,
    focus: u32,
) -> *mut Frame {
    let (w, h) = (width as usize, height as usize);
    if w == 0 || h == 0 || w.saturating_mul(h) > 40_000_000 || port.w <= 0.0 || port.h <= 0.0 {
        return std::ptr::null_mut();
    }
    let mut pixels = vec![0xff342e2b; w * h];
    let mut labels = Vec::new();
    if palette.is_null() || color_count == 0 {
        return std::ptr::null_mut();
    }
    let colors = unsafe { std::slice::from_raw_parts(palette, color_count) };
    let sx = w as f64 / port.w;
    let sy = h as f64 / port.h;
    s.walk(
        |r| {
            if !r.intersects(port) {
                return false;
            }
            let spans_pixel = |origin: f64, length: f64, offset: f64, scale: f64| {
                let extent = length * scale;
                let start = (origin - offset) * scale;
                extent >= 1.0 || start.round() < (start + extent).round()
            };
            spans_pixel(r.x, r.w, port.x, sx) && spans_pixel(r.y, r.h, port.y, sy)
        },
        |r| (r.w * sx) * (r.h * sy) >= 1.0,
        |key, rect, kind| {
            let (x, y) = ((rect.x - port.x) * sx, (rect.y - port.y) * sy);
            let (dw, dh) = (rect.w * sx, rect.h * sy);
            let (x0, x1) = (
                x.round().max(0.0) as usize,
                ((x + dw).round() as usize).min(w),
            );
            let (y0, y1) = (
                y.round().max(0.0) as usize,
                ((y + dh).round() as usize).min(h),
            );
            if x0 >= x1 || y0 >= y1 {
                return false;
            }
            let (group, tint) = match groups {
                Some(g) => {
                    let (id, color) = g.group_color(key);
                    (id, &colors[color as usize % color_count])
                }
                None => (kind, colors.get(kind as usize).unwrap_or(&colors[0])),
            };
            let dim = focus != NONE && group != focus;
            let shade = |color: u32| {
                if dim {
                    let [r, g, b, a] = color.to_le_bytes();
                    let reduce = |v: u8| ((u16::from(v) * 9 + 8) / 16) as u8;
                    u32::from_le_bytes([reduce(r), reduce(g), reduce(b), a])
                } else {
                    color
                }
            };
            let outline = group == focus && focus != NONE && dw.min(dh) >= 5.0 * scale;
            let ink = if tint.light_ink {
                0xfff0f0f0
            } else {
                0xff343434
            };
            let graded = shine && dw >= 2.0 && dh >= 3.0;
            let small_glint = shine && dw >= 2.0 && dh >= 2.0 && !graded;
            let grade_step = 128.0 / dh;
            let right_divider = x1 < w && dw >= 3.0;
            let top_divider = y0 > 0 && y >= 0.5 && dh >= 3.0 && dw >= 2.0;
            let bottom = (y + dh).round();
            for row in y0..y1 {
                let color = if graded && y >= -0.49 && row == y0 {
                    tint.top
                } else if graded && bottom <= h as f64 && row + 1 == y1 {
                    tint.bottom
                } else if graded {
                    let grade = ((row as f64 + 0.5 - y) * grade_step).clamp(0.0, 128.0) as usize;
                    tint.surface[grade]
                } else if small_glint && y >= -0.49 && row == y0 {
                    tint.surface[18]
                } else if top_divider && row == y0 {
                    tint.seam
                } else {
                    tint.surface[64]
                };
                let line = &mut pixels[row * w + x0..row * w + x1];
                if outline && ((row == y0 && y >= -0.49) || (row + 1 == y1 && bottom <= h as f64)) {
                    line.fill(ink);
                } else {
                    line.fill(shade(color));
                    if right_divider {
                        *line.last_mut().unwrap() = shade(tint.seam);
                    }
                    if outline {
                        if x >= -0.49 {
                            line[0] = ink;
                        }
                        if (x + dw).round() <= w as f64 {
                            *line.last_mut().unwrap() = ink;
                        }
                    }
                }
            }
            if !dim && (x1 - x0) as f64 >= 44.0 * scale && (y1 - y0) as f64 >= 21.0 * scale {
                labels.push((
                    (x1 - x0) * (y1 - y0),
                    Label {
                        rect,
                        key,
                        light_ink: tint.light_ink,
                    },
                ));
            }
            false
        },
    );
    labels.sort_unstable_by_key(|a| std::cmp::Reverse(a.0));
    let labels = labels.into_iter().take(64).map(|(_, l)| l).collect();
    Box::into_raw(Box::new(Frame { pixels, labels }))
}
#[unsafe(no_mangle)]
extern "C" fn dt_frame_pixels(f: &Frame) -> *const u8 {
    f.pixels.as_ptr().cast()
}
#[unsafe(no_mangle)]
extern "C" fn dt_frame_labels(f: &Frame, count: &mut usize) -> *const Label {
    *count = f.labels.len();
    f.labels.as_ptr()
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_frame_free(f: *mut Frame) {
    unsafe {
        drop(Box::from_raw(f));
    }
}
