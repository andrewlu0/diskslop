use diskslop::{EntryKind, Inventory, Key, Progress, default_threads};
use serde_json::json;
use std::{
    env,
    ffi::OsStr,
    io::{self, Write},
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    process::{Command, ExitCode},
    time::Instant,
};

const USAGE: &str = "Usage: diskslop [--summary] [--json] [--top N] [--threads N] [--] FOLDER
       diskslop open [--] FOLDER";

fn open_folder(path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let folder = path.canonicalize()?;
    if !folder.is_dir() {
        return Err("Choose a folder to open in DiskSlop.".into());
    }
    let executable = env::current_exe()?.canonicalize()?;
    let mut open = Command::new("/usr/bin/open");
    if let Some(bundle) = executable.ancestors().nth(3)
        && bundle.extension() == Some(OsStr::new("app"))
        && executable.ends_with("Contents/Helpers/diskslop")
    {
        open.arg("-a").arg(bundle);
    } else {
        open.args(["-b", "local.diskslop.app"]);
    }
    if !open.arg(folder).status()?.success() {
        return Err("Could not open the folder in DiskSlop.".into());
    }
    Ok(())
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os().skip(1).peekable();
    if args.peek().is_some_and(|arg| arg == "open") && args.len() > 1 {
        args.next();
        let mut target = args.next();
        if target.as_deref() == Some(OsStr::new("--")) {
            target = args.next();
        }
        if let Some(path) = target {
            if args.next().is_some() {
                return Err(USAGE.into());
            }
            return open_folder(Path::new(&path));
        }
        return Err(USAGE.into());
    }
    let mut as_json = false;
    let mut path = None;
    let mut workers = default_threads();
    let mut top: usize = 20;
    let mut options = true;
    while let Some(arg) = args.next() {
        match arg.to_str().filter(|_| options) {
            Some("-h" | "--help") => {
                println!("{USAGE}");
                return Ok(());
            }
            Some("--") => options = false,
            Some("--json") => as_json = true,
            Some("--summary") => top = 0,
            Some("--threads") => {
                workers = args
                    .next()
                    .and_then(|v| v.to_str()?.parse().ok())
                    .filter(|n| (1..=64).contains(n))
                    .ok_or("--threads requires a number from 1 to 64")?;
            }
            Some("--top") => {
                top = args
                    .next()
                    .and_then(|v| v.to_str()?.parse().ok())
                    .ok_or("--top requires a nonnegative integer")?
            }
            Some(s) if s.starts_with('-') => return Err(USAGE.into()),
            _ if path.is_none() => path = Some(PathBuf::from(arg)),
            _ => return Err(USAGE.into()),
        }
    }
    let path = path.ok_or(USAGE)?;
    let start = Instant::now();
    let scan = Inventory::scan(&path, workers, &Progress::default())?;
    let seconds = start.elapsed().as_secs_f64();
    let mut output = io::stdout().lock();
    if !as_json {
        writeln!(
            output,
            "allocated_bytes={} entries={} errors={} mount_boundaries={} seconds={:.4}",
            scan.total(),
            scan.count(),
            scan.issues,
            scan.boundaries,
            seconds
        )?;
    }
    let mut children = Vec::new();
    if top > 0 {
        for slot in scan.sorted_children(0).into_iter().take(top) {
            let key = Key { folder: 0, slot };
            let kind = scan.kind(key);
            let name = OsStr::from_bytes(scan.name(key)).to_string_lossy();
            if as_json {
                let kind = match kind {
                    EntryKind::File => "file",
                    EntryKind::Directory => "directory",
                    EntryKind::Link => "symlink",
                    EntryKind::Other => "other",
                };
                let mut entry =
                    json!({"name": name, "allocated_bytes": scan.size(key), "kind": kind});
                if std::str::from_utf8(scan.name(key)).is_err() {
                    entry["name_bytes"] = json!(scan.name(key));
                }
                children.push(entry);
            } else {
                let suffix = if kind == EntryKind::Directory {
                    "/"
                } else {
                    ""
                };
                writeln!(
                    output,
                    "{:>15}  {}{}",
                    scan.size(key),
                    name.escape_default(),
                    suffix
                )?;
            }
        }
    }
    if as_json {
        let report = json!({"allocated_bytes": scan.total(), "entries": scan.count(),
            "errors": scan.issues, "mount_boundaries": scan.boundaries, "seconds": seconds,
            "children": children});
        serde_json::to_writer(&mut output, &report)?;
        writeln!(output)?;
    }
    if scan.issues > 0 {
        return Err(
            io::Error::other("The scan is partial. Some metadata could not be read.").into(),
        );
    }
    Ok(())
}
fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
