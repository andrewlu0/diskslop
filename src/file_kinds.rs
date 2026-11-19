use super::{Inventory, Key};
use crate::{EXECUTABLE, EntryKind, FINDER_BUNDLE};
use std::collections::HashMap;
use std::ffi::{CString, c_char};
use std::os::unix::ffi::OsStrExt;

pub(super) type Resolve = extern "C" fn(*const c_char, *const u8, usize, u32, u8) -> u32;
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub(super) struct KindTotal {
    pub bytes: u64,
    pub files: u64,
    pub kind: u32,
}

pub(super) struct Resolver {
    native: Resolve,
    cached: HashMap<(u8, u32), HashMap<Vec<u8>, u32>>,
    lower: Vec<u8>,
}
impl Resolver {
    pub fn new(native: Resolve) -> Self {
        Self {
            native,
            cached: HashMap::new(),
            lower: Vec::new(),
        }
    }
    pub fn kind(&mut self, scan: &Inventory, key: Key) -> u32 {
        let entry = scan.entry(key);
        let folder = entry.kind == EntryKind::Directory;
        let name = scan.name(key);
        let ext = name
            .iter()
            .rposition(|&b| b == b'.')
            .map(|i| &name[i + 1..])
            .unwrap_or_default();
        let bundle = entry.flags & FINDER_BUNDLE != 0;
        if folder && ext.is_empty() && !bundle {
            return 0;
        }
        let traits = u8::from(folder)
            | (u8::from(entry.kind == EntryKind::Link) << 1)
            | (u8::from(!folder && entry.flags & EXECUTABLE != 0) << 2)
            | (u8::from(bundle) << 3)
            | (u8::from(entry.kind == EntryKind::Other) << 4);
        let special = ext.is_empty()
            && matches!(
                name,
                b"Makefile"
                    | b"Dockerfile"
                    | b"Gemfile"
                    | b"README"
                    | b"LICENSE"
                    | b"Rakefile"
                    | b"CMakeLists"
                    | b"Podfile"
            );
        let sig = if special { name } else { ext };
        let signed_traits = if special { traits | 32 } else { traits };
        let cache = self
            .cached
            .entry((signed_traits, entry.finder_type))
            .or_default();
        let sig = if sig.iter().any(u8::is_ascii_uppercase) {
            self.lower.clear();
            self.lower.extend(sig.iter().map(u8::to_ascii_lowercase));
            self.lower.as_slice()
        } else {
            sig
        };
        if let Some(&id) = cache.get(sig) {
            return id;
        }
        let path = CString::new(scan.path(key).as_os_str().as_bytes()).unwrap();
        let id = (self.native)(
            path.as_ptr(),
            ext.as_ptr(),
            ext.len(),
            entry.finder_type,
            signed_traits,
        );
        cache.insert(sig.to_vec(), id);
        id
    }
}
