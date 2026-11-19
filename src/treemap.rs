use super::{Key, Model, NONE};
use std::mem::size_of;
use std::sync::OnceLock;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl Rect {
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
    tone: u8,
}
#[derive(Default)]
struct Sheet {
    bounds: Vec<Rect>,
    order: Vec<Mark>,
    bands: Vec<Rect>,
}
struct Scene {
    sheets: Vec<Sheet>,
    root: u32,
    files: usize,
}

const GROUP: usize = 32;
const COLORS: [u32; 12] = [
    0x287f89, 0x3867a0, 0x8a629f, 0xad5c71, 0xaa793f, 0x688b55, 0x397ca5, 0x7064a3, 0xb76c48,
    0x369285, 0x93804e, 0x547a98,
];

fn hash_name(name: &[u8]) -> u32 {
    name.iter().fold(2166136261u32, |h, &c| {
        (h ^ u32::from(c)).wrapping_mul(16777619)
    })
}

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

impl Scene {
    fn new(m: &Model, root: u32, aspect: f64) -> Self {
        let scan = m.scan.read().unwrap();
        let aspect = aspect.clamp(0.05, 32.0);
        let mut sheets: Vec<Sheet> = (0..scan.folders.len()).map(|_| Sheet::default()).collect();
        let mut mass = vec![0u64; sheets.len()];
        let mut folders = vec![root];
        let mut index = 0;
        let mut files = 0;
        while index < folders.len() {
            let id = folders[index] as usize;
            let f = &scan.folders[id];
            for &slot in &scan.order[id] {
                let e = &f.entries[slot as usize];
                if e.child == NONE {
                    mass[id] = mass[id].saturating_add(e.bytes.max(1));
                    files += 1;
                } else {
                    folders.push(e.child);
                }
            }
            index += 1;
        }
        for &id in folders.iter().skip(1).rev() {
            let parent = scan.folders[id as usize].parent.unwrap().folder as usize;
            mass[parent] = mass[parent].saturating_add(mass[id as usize]);
        }
        let mut pending = vec![(
            root,
            Rect {
                x: 0.0,
                y: 0.0,
                w: aspect,
                h: 1.0,
            },
            0u8,
        )];
        let mut weighted = Vec::new();
        while let Some((dir, rect, family)) = pending.pop() {
            let id = dir as usize;
            let f = &scan.folders[id];
            let sheet = &mut sheets[id];
            weighted.clear();
            let mut file_rank = 0;
            for &slot in &scan.order[id] {
                let e = &f.entries[slot as usize];
                let weight = if e.child == NONE {
                    e.bytes.max(1)
                } else {
                    mass[e.child as usize]
                };
                if weight == 0 {
                    continue;
                }
                let shift = if e.child != NONE {
                    hash_name(f.name(slot as usize)) % COLORS.len() as u32
                } else {
                    let order = [0, 3, 5, 1, 4, 7, 9, 8, 6, 2, 10, 11];
                    let shift = order[file_rank % order.len()];
                    file_rank += 1;
                    shift
                };
                let tone = (u32::from(family) + shift) as u8 % COLORS.len() as u8;
                weighted.push(Weighted {
                    mark: Mark {
                        slot,
                        child: e.child,
                        tone,
                    },
                    weight: weight as f64,
                });
            }
            if !weighted.windows(2).all(|w| w[0].weight >= w[1].weight) {
                weighted.sort_by(|a, b| b.weight.total_cmp(&a.weight));
            }
            sheet.bounds.resize(f.entries.len(), Rect::default());
            sheet.order.reserve_exact(weighted.len());
            squarify(&weighted, mass[id] as f64, rect, |mark, cell| {
                if mark.child != NONE {
                    pending.push((mark.child, cell, mark.tone));
                }
                let normal = Rect {
                    x: cell.x / aspect,
                    w: cell.w / aspect,
                    ..cell
                };
                sheet.bounds[mark.slot as usize] = normal;
                if sheet.order.len().is_multiple_of(GROUP) {
                    sheet.bands.push(normal);
                } else if let Some(last) = sheet.bands.last_mut() {
                    *last = last.union(normal);
                }
                sheet.order.push(mark);
            });
        }
        Self {
            sheets,
            root,
            files,
        }
    }

    fn walk(
        &self,
        intersects: impl Fn(Rect) -> bool,
        mut visit: impl FnMut(Key, Rect, u8) -> bool,
    ) {
        let mut pending = vec![self.root];
        while let Some(folder) = pending.pop() {
            let sheet = &self.sheets[folder as usize];
            for (band, marks) in sheet.bands.iter().zip(sheet.order.chunks(GROUP)) {
                if !intersects(*band) {
                    continue;
                }
                for mark in marks {
                    let r = sheet.bounds[mark.slot as usize];
                    if !intersects(r) {
                        continue;
                    }
                    if mark.child != NONE {
                        pending.push(mark.child);
                    } else if visit(
                        Key {
                            folder,
                            slot: mark.slot,
                        },
                        r,
                        mark.tone,
                    ) {
                        return;
                    }
                }
            }
        }
    }
}

#[unsafe(no_mangle)]
extern "C" fn dt_map_new(m: &Model, root: u32, aspect: f64) -> *mut Scene {
    Box::into_raw(Box::new(Scene::new(m, root, aspect)))
}
#[unsafe(no_mangle)]
unsafe extern "C" fn dt_map_free(s: *mut Scene) {
    unsafe {
        drop(Box::from_raw(s));
    }
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_count(s: &Scene) -> usize {
    s.files
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_memory(s: &Scene) -> usize {
    s.sheets.capacity() * size_of::<Sheet>()
        + s.sheets
            .iter()
            .map(|f| {
                (f.bounds.capacity() + f.bands.capacity()) * size_of::<Rect>()
                    + f.order.capacity() * size_of::<Mark>()
            })
            .sum::<usize>()
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_bounds(s: &Scene, key: Key, out: &mut Rect) -> bool {
    if let Some(&r) = s
        .sheets
        .get(key.folder as usize)
        .and_then(|f| f.bounds.get(key.slot as usize))
        && r.w > 0.0
        && r.h > 0.0
    {
        *out = r;
        return true;
    }
    false
}
#[unsafe(no_mangle)]
extern "C" fn dt_map_hit(s: &Scene, x: f64, y: f64, out: &mut Key) -> bool {
    let mut hit = false;
    s.walk(
        |r| r.contains(x, y),
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
    rgb: u32,
}
struct Frame {
    pixels: Vec<u32>,
    labels: Vec<Label>,
}

fn shades() -> &'static [[u32; 64]; COLORS.len()] {
    static TABLE: OnceLock<[[u32; 64]; COLORS.len()]> = OnceLock::new();
    TABLE.get_or_init(|| {
        std::array::from_fn(|tone| {
            std::array::from_fn(|level| {
                let base = COLORS[tone];
                let light = (level as f32 - 25.0) / 112.0;
                let channel = |offset: u32| {
                    let c = ((base >> offset) & 255) as f32;
                    (if light > 0.0 {
                        c + (255.0 - c) * light
                    } else {
                        c * (1.0 + light)
                    }) as u32
                };
                channel(16) | (channel(8) << 8) | (channel(0) << 16) | 0xff000000
            })
        })
    })
}

#[unsafe(no_mangle)]
extern "C" fn dt_map_render(
    s: &Scene,
    port: Rect,
    width: u32,
    height: u32,
    scale: f64,
) -> *mut Frame {
    let (w, h) = (width as usize, height as usize);
    if w == 0 || h == 0 || w.saturating_mul(h) > 40_000_000 || port.w <= 0.0 || port.h <= 0.0 {
        return std::ptr::null_mut();
    }
    let mut pixels = vec![0xff342e2b; w * h];
    let mut labels = Vec::new();
    let colors = shades();
    let sx = w as f64 / port.w;
    let sy = h as f64 / port.h;
    s.walk(
        |r| r.intersects(port),
        |key, rect, tone| {
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
            let shades = &colors[tone as usize];
            let rim = dw > 8.0 * scale && dh > 7.0 * scale;
            let depth = if dh > 14.0 * scale { 22.0 / dh } else { 0.0 };
            for row in y0..y1 {
                let level = if depth == 0.0 {
                    23
                } else {
                    (39.0 - (row as f64 - y) * depth).clamp(8.0, 45.0) as usize
                };
                let line = &mut pixels[row * w + x0..row * w + x1];
                if rim && y >= -0.49 && row == y0 {
                    line.fill(shades[51]);
                } else {
                    line.fill(shades[level]);
                    if rim && x >= -0.49 {
                        line[0] = shades[47];
                    }
                    if rim && x + dw <= w as f64 + 0.49 {
                        *line.last_mut().unwrap() = shades[10];
                    }
                }
            }
            if (x1 - x0) as f64 >= 44.0 * scale && (y1 - y0) as f64 >= 21.0 * scale {
                labels.push((
                    (x1 - x0) * (y1 - y0),
                    Label {
                        rect,
                        key,
                        rgb: COLORS[tone as usize],
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
