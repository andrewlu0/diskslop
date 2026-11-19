# DiskTally

DiskTally is a native macOS disk-usage explorer. A Rust scanner reads file metadata in bulk. An AppKit outline and a zoomable, file-only treemap share the same index.

## Run it

Open `DiskTally.app` in the repository. Choose **Volume** for a mounted startup, external, or network volume, or **Choose Folder** for a directory. The volume picker can also show hidden system mounts. Scan scope follows the selected filesystem and the current user’s access.

To build on macOS with a current Rust toolchain and a Swift compiler with the macOS 26 SDK or later, run `./build-app.sh`. The script creates and locally signs `DiskTally.app` for the host architecture. It also builds the Rust CLI. For an allocated-byte total, run `target/release/disktally --summary /path/to/folder`. The app targets macOS 13 and later. Native Liquid Glass is available on macOS 26 and later.

## Navigate the map

| Gesture | Result |
| --- | --- |
| Click a file tile | Expands its ancestors, selects the exact file, scrolls to its outline row, and shows its allocated size. |
| Click a folder in the outline | Highlights the contiguous footprint of its files, including nested descendants. |
| Double-click a folder in the outline | Fills the map with that subtree. The enclosing-folder toolbar button goes back up. |
| Click the glass zoom buttons or press ⌘+ / ⌘− | Magnifies or reduces the map. |
| Command-scroll or pinch | Zooms around the pointer. Normal scrolling or Option-drag pans a magnified map. |
| Double-click a tile, or press ⇧⌘F | Fits the selected file or folder footprint. ⌘0 restores the overview. |
| Control-click or Command-click | Adds or removes an item from the selection. |
| Shift-click | Selects a range in visible outline order. Adding Command or Control extends the existing selection. |
| Drag on the map or in the outline | Selects the files intersecting a rectangle, or a contiguous run of outline rows. |
| Right-click | Opens a native menu with Open, Open With, Open in Finder, Refresh, and Move to Trash. |

Open in Finder and Move to Trash occupy a dedicated footer below the map. A single selected folder opens in Finder. For files or a multiple selection, Finder reveals the selected items.

Every Trash action opens a review sheet showing the selected paths, their allocated bytes and the scanned count of files and folders inside them. Return and Escape cancel. Moving a parent folder includes its descendants once. The Rust backend blocks a complete scanned volume or home folder, including a marquee covering every scanned file, and protects folders containing nested mounts. A selection covering at least half the scanned bytes of a volume or home folder needs an extra acknowledgment in the same sheet.

DiskTally uses the native Trash operation under the signed-in account’s permissions. A macOS refusal leaves the affected item in place. The app reports partial results and offers **Show in Finder** for the first affected item. Finder then handles any separate action you choose there.

## Layout and scan behavior

The layout applies the squarified treemap algorithm independently within each directory. Each file has a square-cornered rectangle. Folders supply geometric bounds for grouping and selection. Allocated bytes determine area. Each zero-allocation entry gets one byte of *visual weight* so it can be found under magnification. The size column always shows its actual allocated bytes. Empty folders and directory metadata take no map area. At overview scale multiple rectangles may share a physical pixel. [Squarified Treemaps, Bruls, Huizing and van Wijk](https://research.tue.nl/en/publications/squarified-treemaps/)

Rust lays out the file shapes and rasterizes the visible portion on a background thread. The index provides precise hit testing at every zoom level. The app reprojects the previous frame during a gesture while the next frame renders. Large visible tiles can use native square Liquid Glass surfaces. Smaller tiles share a single shaded image. The outline uses reusable AppKit rows and preordered child indexes. The app honors Reduce Transparency.

The scanner requests metadata through Darwin’s bulk directory API with a descriptor-based fallback. It counts each hard-linked allocation once, measures sparse files by their allocated blocks, skips Trash directories and stays within the selected mount. Symlinks are listed without traversing their targets. The status bar reports read errors and skipped mount boundaries. APFS clones can share storage, so the reported allocation can differ from space recovered after emptying Trash. [Apple’s bulk directory API](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/getattrlistbulk.2)

Recent roots stay in memory while the app is open. DiskTally keeps up to three, targeting 512 MiB of estimated scan and geometry storage. A single larger scan can occupy the cache on its own. On reopen it checks the filesystem identity and flushes the local filesystem event stream. Changed paths trigger a background refresh of affected subtrees. Network mounts, incomplete scans, and missing or dropped events trigger a fresh scan. The toolbar’s Rescan always rereads the root. [Apple’s filesystem event guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)

[Performance measurements and Disk Inventory X comparison](BENCHMARKS.md)
