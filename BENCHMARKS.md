# Performance

Measured on an Apple M4 Pro running macOS 27.0.1. The tests used the local APFS volume with a warm filesystem cache. Startup, command-line scanning, rendering, and moving to Trash were timed separately.

## Interactive rendering

An M4 Pro reopened the same frozen APFS inventory with **3,714,774 file shapes** in instrumented, optimized builds of 0.1.8 and 0.1.9. The treemap measured 2,122 × 1,660 pixels. Two runs per version used the same viewport sequence, selections and native outline. The ranges below are the two runs’ 95th percentiles.

| Interaction | Samples per run | 0.1.8 | 0.1.9 |
| --- | ---: | ---: | ---: |
| Treemap zoom or pan, main-thread update through Core Animation commit | 192 | 16.0–16.2 ms | 0.59–1.51 ms |
| Single-file selection through commit | 120 | 0.91–1.06 ms | 0.028–0.033 ms |
| Native outline scroll through commit | 180 | 17.5–39.4 ms | 3.89–4.41 ms |
| Sunburst zoom, Metal command buffer GPU time | 468–471 | 0.62–0.63 ms | 0.55–0.63 ms |

The treemap stayed within the 8.33 ms CPU budget for 120 Hz on all 384 measured moves in 0.1.9. Expanding 25,342 children in the native outline still took a median **15–19 ms**, with the first expansion taking **69–86 ms**. Selecting a sunburst folder and starting navigation now schedules the highlighted artwork on a worker. The previous version painted the outgoing chart on the main thread for a median **285–290 ms**.

The display was locked. These measurements cover main-thread work and GPU execution with offscreen drawables. Physical presentation cadence requires an active display. Separate native interaction checks covered zoom reversal, Reduce Motion, selection through 25 folder levels, live refresh, and Trash reflow in both charts.

## Opening a document

On a generated tree containing **50,048 entries** across 128 groups and six subfolders per group, opening a fresh DiskSlop window took a median **0.509 s** with the Finder icons and file-kind legend. Disk Inventory X 1.3 took **5.018 s**, a **9.9×** difference. Each run launched a new process. Both apps had to show a document window with the requested name and a populated native outline with a nonzero-height visible row. DiskSlop additionally had to report a completed file raster. The timer included launch and accessibility polling. Each app had one warm-up followed by three alternating measured launches. These are warm-cache observations on the local APFS volume.

| Application | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| DiskSlop, native Apple silicon | 0.476 s | 0.517 s | 0.509 s |
| Disk Inventory X 1.3, Intel under Rosetta | 4.996 s | 5.018 s | 5.021 s |

## Scanning

Median total command runtime in seconds. One warm-up and seven interleaved runs per tool and tree. DiskSlop, macOS du and dua returned identical allocated-byte totals on all three inputs. The runs shared an active desktop, so the small timing differences are sensitive to system load.

| Tree | Entries | DiskSlop | macOS du | dua 3.0.3 | szt 1.0.0 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Nested generated tree | 50,048 | 0.0376 | 0.1582 | 0.0563 | 0.0331 |
| One wide directory | 24,000 | 0.0364 | 0.0569 | 0.0836 | 0.0354 |
| Installed Xcode bundle | 167,225 | 0.6568 | 4.3234 | 1.2305 | 0.5286 |

Use `python3 bench.py /path/to/tree` after building. Optional `--dua` and `--szt` arguments take paths to those tools. The script times summaries and prints individual runs. Cold disks, network shares, and full-volume scans have different performance characteristics. [dua](https://github.com/Byron/dua-cli)

On the startup Data volume of a 14-core M4 Pro, one indexed scan took **15.45 s** for 4,877,201 entries with 853 read errors. An immediate refresh retried failed directories and incorporated 66 changed directory paths from the local event stream in **2.10 s**. It returned 4,877,220 entries with 853 read errors. The filesystem was active during the measurement. These timings cover the app’s Rust index and refresh, excluding map layout and window rendering.

### Browsing during a full scan

With the startup Data volume at 97% capacity, a forced full scan laid out the three-pane workspace in 6 ms. The first populated map was visible by **167 ms** with 13,023 file shapes, 139 kinds and 20 rows in the folder outline. The native app presented **35 intermediate inventories** at a median interval of **302 ms** and finished **4,904,745 entries in 18.32 s**. The optimized AppKit probe bypassed the saved index and used the macOS filesystem cache. Timing began at the scan action.

During that scan the probe switched the sidebar to Largest Files, switched the chart to Sunburst, and clicked a wedge and a treemap tile through their native mouse handlers. The last selection survived subsequent updates and completion. A separate launch restored the saved index with Largest Files and Sunburst selected. The ranking was usable while the map was being prepared.

### Reopening the startup disk after quitting

On a 14-core M4 Pro with 48 GiB of memory, the signed test app opened the startup Data volume and drew its first complete treemap in **39.24 s** with an empty DiskSlop cache. The next two launches took **9.80 s** and **10.32 s**, including launch, event replay, map construction and drawing. Each launch ran in a new process. The measurement ended when the native treemap reported a completed raster with over 4.3 million file shapes. The first launch wrote an 83.0 MiB index. The next two reused it.

A separate benchmark ran the production indexer and root map builder three times per method in fresh processes, on the same active volume with about 4.93 million entries. The filesystem cache was warm, and the full-scan baseline omitted the cost of saving the index. Both paths encountered 854–855 read errors and skipped 10 mounts.

| Median elapsed | Full scan | Persistent reopen | Speedup |
| --- | ---: | ---: | ---: |
| Inventory ready | 24.59 s | 3.61 s | 6.8× |
| Inventory and root map geometry ready | 33.04 s | 9.73 s | 3.4× |

For the storage comparison, the same 5.00-million-entry index occupied 355.9 MiB unpacked. Zstandard level 1 used **84.7 MiB** and the application wrote it in **0.97 s**. LZ4 used 138.7 MiB. Zstandard level 3 used 78.0 MiB. Median standalone decode times were 0.24 s, 0.16 s and 0.27 s respectively. The app uses level 1 to keep both checkpoint size and write time low.

A controlled tree was scanned, the process exited, and its files were changed. On relaunch the indexed paths, allocated bytes, partial-directory flags and entry counts matched a new full scan after an in-place write, permission changes, a subtree rename, new nested files, deletion and hard-link changes. A truncated checkpoint was rejected.

### Screen-resolution treemap

On the same 14-core M4 Pro with 48 GiB RAM, two signed release builds reopened the startup Data volume from the persistent index. Each build ran in four fresh processes, interleaved, and each process confirmed a cache hit. At the first complete frame the map contained roughly 4.34 million files at 2,122 × 1,660 physical pixels. Timing probes measured launch through the first completed AppKit draw, then four zoom-in and four zoom-out commands per process through the draw of the requested viewport.

| Measurement | Eager layout | Screen-resolution layout |
| --- | ---: | ---: |
| Cached reopen, median | 10.87 s | 9.71 s |
| Resident memory at the first complete draw, median | 1,493 MiB | 1,378 MiB |
| Native zoom command to draw, median (32 steps per build) | 20.8 ms | 22.2 ms |
| Native zoom command to draw, 95th percentile | 51.8 ms | 48.4 ms |

The volume and desktop were active throughout. Individual reopen times ranged from 9.50 to 32.47 s for eager layout and 9.41 to 11.25 s for screen-resolution layout. A separate smoke launch of the final signed bundle reached the complete map in 25.27 s and completed all eight zoom steps. Cache-hit status was unavailable in that uninstrumented launch.

To isolate layout cost, both Rust renderers also opened the same saved inventory with a deterministic kind resolver and drew the same viewport in three fresh processes each. At 2,122 × 1,660, overview geometry fell from **398 MiB to 245 MiB**, and median scene construction plus first raster fell from **644 ms to 553 ms**. At 1,440 × 960 the new overview occupied **219 MiB**. These figures exclude scan-index storage.

For the deep-zoom check, each renderer drew the interior of 24 separate folders that initially occupied less than one physical pixel. At 2,122 × 1,660, the median first raster of a previously unvisited target took **1.08 ms** with eager layout and **1.23 ms** on demand, across 72 frames per build. Rendered pixel checksums, center hits and marquee-selected keys matched for all targets. An additional folder-edit check verified that returning to an expanded branch reused its geometry, zero-allocation files remained selectable, and an incremental refresh updated the branch bounds.

## Interaction

On a local APFS tree with 33,699 entries, two rounds of five consecutive ⌘R refreshes had a **5 ms median** from the native command to validation, with observations from below 1 ms to 20 ms. All ten retained the same inventory and map, expanded folders, selected file and viewport. Adding 241 files to one directory produced one changed-directory record. The Rust refresh enumerated 241 entries in **0.39–0.41 ms**, and the window finished updating in **33.3–34.3 ms**. Force Full Scan on the resulting 33,940 entries took **99.9–107.3 ms** end to end. Both returned identical allocated bytes and entry counts. A separate rename and hard-link change also matched an independent full scan.

During two fresh scans of 167,225 entries in the installed Xcode bundle, the first native Largest Files table was visible after **157 ms** and **197 ms**, with 48,492 and 76,296 entries examined at observation time. Both scans finished with the 100 largest regular files. These are local warm-filesystem measurements with the optimized scanner and AppKit interface.

- **Treemap.** The Xcode tree had 137,232 file shapes, including 11,205 zero-allocation entries. Their areas summed to the full map within floating-point tolerance. The geometry used 15.50 MiB. Construction, including kind lookup and package statistics, took 81.0 ms. The 1,500 × 1,000-pixel gradient overview rendered in about 4.6 ms with a warmed allocator. A render centered on the smallest rectangle took 0.25 ms. These timings cover the file raster and label preparation. Display composition adds work. Center-point hit tests on a systematic sample matched the original file keys, and the containing folder ranges covered those rectangles.
- **Folder outline.** Expanding a folder with 24,000 children took 27.2 ms the first time and about 10.6 ms on subsequent expansions. Collapse took 6.3 ms initially and about 6.0 ms on subsequent collapses. Revealing a file four levels down took 33.4 ms and reached its exact 4,096-byte row.
- **Cached reopen.** Two observations of an unchanged local test root took 3.9 ms and 20.6 ms for identity and event-stream validation. A recently written fixture also triggered conservative revalidation while macOS delivered its coalesced events. After nested writes and a rename, incremental refresh produced the same allocation and entry count as a fresh scan.
- **Trash.** Moving an isolated generated folder containing 4,041 entries took 164 ms. This included preparing the batch review, performing the system Trash operation, updating the index, and rendering the resulting 1,500 × 1,000-pixel map. It excludes the time a person spends reading the review. The same check verified that an unrelated hard link retained its allocation and that a replaced file stayed in place. This single local measurement depends on the volume and filesystem load.

### Live updates on the startup disk

The startup Data volume on this M4 Pro reported 95–96% used and 20–24 GiB available during this run. A fresh launch of the instrumented release build took **33.36 s** to index **4,992,780 entries** and display the first complete treemap. The scan reported 855 read errors. The Rust inventory occupied 674 MiB and the treemap geometry occupied 398 MiB.

| Interaction with the whole volume open | Observed time |
| --- | ---: |
| Create a file immediately after enabling Live, including accumulated filesystem changes | 1.265 s |
| Grow the selected file five times with the folder tree and treemap visible | **568 ms median**, 360–672 ms |
| Grow the file twice with Largest Files, the sunburst, and Creation Date coloring active | 796 ms and 224 ms |
| Press ⌘R with other filesystem activity and the same 855 read errors | 2.60 s |

The live timings start at the file write and end when the native window publishes the new inventory and map. The five growth checks also read the selected row’s displayed size. Across 15 treemap updates, installing the prepared results on the main thread took **0.92 ms median** and **38.2 ms maximum**. The animation continues after installation. Peak resident memory was 2,051 MiB with the treemap and 2,183 MiB after switching to the sunburst and date coloring. The probe wrote one temporary file of at most 480 KiB. Other processes continued changing the volume throughout.

A two-launch AppKit check used a separate APFS test tree and shortened the checkpoint timer. Thirty writes to one file produced one replacement of the compressed index. Its stored allocation matched the filesystem. Live then displayed the cache file’s own allocation without writing another checkpoint. A fresh process restored that index and picked up file growth, a rename, a deletion and a newly created subtree from the closed interval. A further write appeared in the reopened window.

## Trash review and filesystem permissions

On a mounted read-only test volume, the backend rejected selecting the root itself, all root rows, and all map tiles. Selecting a file covering 98% of the scanned bytes required explicit acknowledgment. A permitted subset reached the macOS Trash API, which refused both items and left the folder contents intact. A separate folder on a writable volume also stayed in place when its parent denied write access. Both refusals returned the affected path for Show in Finder. A confirmed batch on a writable test directory moved the two selected items and preserved their neighbor.

In the native review sheet, Return and Escape canceled. The table listed every selected root, and the large-selection checkbox enabled the Move to Trash button only after acknowledgment.

## What Disk Inventory X does

Inspection of the installed Disk Inventory X 1.3 executable with REA showed that it recursively loads filesystem items with Foundation metadata, including size and kind. It builds folder totals and refreshes file-kind statistics as part of opening a document. Its normal Trash path calls the native system Trash API, detaches the item from the model and walks the removed subtree to update file-kind statistics.

Its kind resolver caches the localized description of the uniform type, with the URL’s localized type description as a fallback. The statistics pass groups by that description and sums bytes and counts. Its package-contents option controls whether packages count as individual items or expose their contents. In the original legend the largest kinds receive the first palette colors. DiskSlop uses persistent type colors across scopes, keeps the file-level hit targets, and updates the header and kind highlight on hover. [Original Disk Inventory X screenshots](https://www.derlien.com/screenshots/index.html)

DiskSlop uses the same recoverable macOS Trash operation. Its scan batches directory metadata, and its removal bookkeeping updates ancestor totals and any affected hard-link owners from an index. Rendering and map rebuilding run off the main thread. The launch timings include the combined cost of those operations. [Disk Inventory X](https://www.derlien.com/)
