use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use crate::{EntryKind, Folder, Progress};

const COMMON_ERROR: u32 = 0x2000_0000;
const COMMON: u32 = libc::ATTR_CMN_RETURNED_ATTRS
    | COMMON_ERROR
    | libc::ATTR_CMN_NAME
    | libc::ATTR_CMN_OBJTYPE
    | libc::ATTR_CMN_FILEID;
const FILE: u32 = libc::ATTR_FILE_LINKCOUNT | libc::ATTR_FILE_ALLOCSIZE;
thread_local! { static BUFFER: RefCell<Vec<u64>> = RefCell::new(vec![0; 8192]); }

pub struct Facts {
    pub inode: u64,
    pub bytes: u64,
    pub finder_type: u32,
    pub executable: bool,
    pub bundle: bool,
    pub linked: bool,
    pub kind: EntryKind,
}

pub fn open_dir(path: &Path, device: u64, inode: u64) -> io::Result<(File, u64)> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW_ANY | libc::O_CLOEXEC)
        .open(path)?;
    let meta = file.metadata()?;
    if (meta.dev(), meta.ino()) != (device, inode) {
        return Err(io::Error::other(
            "The folder changed or a volume boundary was reached.",
        ));
    }
    Ok((file, meta.blocks() * 512))
}

pub fn stat_at(fd: &File, name: &CStr) -> io::Result<libc::stat> {
    let mut result = std::mem::MaybeUninit::uninit();
    let rc = unsafe {
        libc::fstatat(
            fd.as_raw_fd(),
            name.as_ptr(),
            result.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { result.assume_init() })
}

fn fallback_entry(fd: &File, name: &CStr, device: u64, folder: &mut Folder) {
    match stat_at(fd, name) {
        Ok(s) if u64::from(s.st_dev as u32) == device => {
            let kind = match s.st_mode & libc::S_IFMT {
                libc::S_IFDIR => EntryKind::Directory,
                libc::S_IFREG => EntryKind::File,
                libc::S_IFLNK => EntryKind::Link,
                _ => EntryKind::Other,
            };
            folder.push(
                name.to_bytes(),
                Facts {
                    inode: s.st_ino,
                    bytes: s.st_blocks.max(0) as u64 * 512,
                    finder_type: 0,
                    executable: s.st_mode & 0o111 != 0,
                    bundle: false,
                    linked: s.st_nlink > 1 && kind != EntryKind::Directory,
                    kind,
                },
            );
        }
        Ok(_) => folder.boundaries += 1,
        Err(_) => folder.issues += 1,
    }
}

struct Stream(*mut libc::DIR);
impl Drop for Stream {
    fn drop(&mut self) {
        unsafe {
            libc::closedir(self.0);
        }
    }
}

fn fallback(fd: &File, device: u64, folder: &mut Folder, progress: &Progress) -> io::Result<()> {
    let copy = unsafe {
        libc::openat(
            fd.as_raw_fd(),
            c".".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
        )
    };
    if copy < 0 {
        return Err(io::Error::last_os_error());
    }
    let stream = unsafe { libc::fdopendir(copy) };
    if stream.is_null() {
        let err = io::Error::last_os_error();
        drop(unsafe { File::from_raw_fd(copy) });
        return Err(err);
    }
    let stream = Stream(stream);
    loop {
        progress.check()?;
        unsafe {
            *libc::__error() = 0;
        }
        let ent = unsafe { libc::readdir(stream.0) };
        if ent.is_null() {
            let err = io::Error::last_os_error();
            return if err.raw_os_error() == Some(0) {
                Ok(())
            } else {
                Err(err)
            };
        }
        let name = unsafe { CStr::from_ptr((*ent).d_name.as_ptr()) };
        if !matches!(name.to_bytes(), b"." | b"..") {
            fallback_entry(fd, name, device, folder);
        }
    }
}

fn word(r: &[u8], pos: usize) -> Option<u32> {
    Some(u32::from_ne_bytes(r.get(pos..pos + 4)?.try_into().ok()?))
}
fn wide(r: &[u8], pos: usize) -> Option<u64> {
    Some(u64::from_ne_bytes(r.get(pos..pos + 8)?.try_into().ok()?))
}

fn parse_record(r: &[u8], fd: &File, device: u64, folder: &mut Folder) -> Option<()> {
    let common = word(r, 4)?;
    let dirs = word(r, 12)?;
    let files = word(r, 16)?;
    let mut p = 24;
    if common & COMMON_ERROR != 0 {
        if word(r, p)? != 0 {
            folder.issues += 1;
            return Some(());
        }
        p += 4;
    }
    if common & libc::ATTR_CMN_NAME == 0 {
        return None;
    }
    let start = p.checked_add_signed(word(r, p)? as i32 as isize)?;
    let len = word(r, p + 4)? as usize;
    let name = CStr::from_bytes_with_nul(r.get(start..start.checked_add(len)?)?).ok()?;
    let raw = name.to_bytes();
    if raw.is_empty() || raw.contains(&b'/') || matches!(raw, b"." | b"..") {
        return None;
    }
    p += 8;
    if common & (libc::ATTR_CMN_OBJTYPE | libc::ATTR_CMN_FILEID)
        != libc::ATTR_CMN_OBJTYPE | libc::ATTR_CMN_FILEID
    {
        fallback_entry(fd, name, device, folder);
        return Some(());
    }
    let kind = match word(r, p)? {
        1 => EntryKind::File,
        2 => EntryKind::Directory,
        5 => EntryKind::Link,
        _ => EntryKind::Other,
    };
    p += 4;
    let mut finder_type = 0;
    let mut bundle = false;
    if common & libc::ATTR_CMN_FNDRINFO != 0 {
        let info = r.get(p..p + 32)?;
        if kind == EntryKind::File {
            finder_type = u32::from_be_bytes(info[..4].try_into().ok()?);
        }
        bundle = u16::from_be_bytes([info[8], info[9]]) & 0x2000 != 0;
        p += 32;
    }
    let mut executable = false;
    if common & libc::ATTR_CMN_ACCESSMASK != 0 {
        executable = word(r, p)? & 0o111 != 0;
        p += 4;
    }
    let inode = wide(r, p)?;
    p += 8;
    if dirs & libc::ATTR_DIR_MOUNTSTATUS != 0 {
        if word(r, p)? & libc::DIR_MNTSTATUS_MNTPOINT != 0 {
            folder.boundaries += 1;
            return Some(());
        }
        p += 4;
    }
    if kind == EntryKind::Directory {
        folder.push(
            raw,
            Facts {
                inode,
                bytes: 0,
                finder_type,
                executable: false,
                bundle,
                linked: false,
                kind,
            },
        );
    } else if files & FILE == FILE {
        let bytes = wide(r, p + 4)? as i64;
        folder.push(
            raw,
            Facts {
                inode,
                bytes: bytes.max(0) as u64,
                finder_type,
                executable,
                bundle,
                linked: word(r, p)? > 1,
                kind,
            },
        );
    } else {
        fallback_entry(fd, name, device, folder);
    }
    Some(())
}

pub fn enumerate(
    fd: &File,
    device: u64,
    folder: &mut Folder,
    progress: &Progress,
    file_kinds: bool,
) -> io::Result<()> {
    let kind_attrs = if file_kinds {
        libc::ATTR_CMN_FNDRINFO | libc::ATTR_CMN_ACCESSMASK
    } else {
        0
    };
    let mut attrs = libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: COMMON | kind_attrs,
        volattr: 0,
        dirattr: libc::ATTR_DIR_MOUNTSTATUS,
        fileattr: FILE,
        forkattr: 0,
    };
    BUFFER.with_borrow_mut(|words| {
        let capacity = std::mem::size_of_val(words.as_slice());
        loop {
            progress.check()?;
            let n = unsafe {
                libc::getattrlistbulk(
                    fd.as_raw_fd(),
                    &mut attrs as *mut _ as *mut _,
                    words.as_mut_ptr().cast(),
                    capacity,
                    0,
                )
            };
            if n == 0 {
                return Ok(());
            }
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                if folder.entries.is_empty()
                    && matches!(
                        err.raw_os_error(),
                        Some(libc::ENOTSUP | libc::EINVAL | libc::ENOSYS)
                    )
                {
                    return fallback(fd, device, folder, progress);
                }
                return Err(err);
            }
            let mut rest =
                unsafe { std::slice::from_raw_parts(words.as_ptr().cast::<u8>(), capacity) };
            for _ in 0..n {
                let len = word(rest, 0).unwrap_or(0) as usize;
                if len < 24 || len > rest.len() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Invalid filesystem metadata record length.",
                    ));
                }
                if parse_record(&rest[..len], fd, device, folder).is_none() {
                    folder.issues += 1;
                }
                rest = &rest[len..];
            }
        }
    })
}

pub fn checked_name(bytes: &[u8]) -> io::Result<CString> {
    CString::new(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "Invalid filename."))
}
