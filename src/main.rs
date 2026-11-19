use disktally::{EntryKind, Inventory, Key, Progress, default_threads};
use std::{
    env, ffi::OsStr, io, os::unix::ffi::OsStrExt, path::PathBuf, process::ExitCode, time::Instant,
};

const USAGE: &str = "disktally [--summary] [--top N] [--threads N] [--] FOLDER";

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os().skip(1);
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
    println!(
        "allocated_bytes={} entries={} errors={} mount_boundaries={} seconds={:.4}",
        scan.total(),
        scan.count(),
        scan.issues,
        scan.boundaries,
        start.elapsed().as_secs_f64()
    );
    if top > 0 {
        for slot in scan.sorted_children(0).into_iter().take(top) {
            let key = Key { folder: 0, slot };
            let suffix = if scan.kind(key) == EntryKind::Directory {
                "/"
            } else {
                ""
            };
            let name = OsStr::from_bytes(scan.name(key)).to_string_lossy();
            println!(
                "{:>15}  {}{}",
                scan.size(key),
                name.escape_default(),
                suffix
            );
        }
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
