# Performance

Measured on an Apple M4 Pro running macOS 27.0.1. The tests used the local APFS volume with a warm filesystem cache. Startup, command-line scanning, rendering, and moving to Trash were timed separately.

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

## Interaction

- **Treemap.** The Xcode tree had 137,232 file shapes, including 11,205 zero-allocation entries. Their areas summed to the full map within floating-point tolerance. The geometry used 15.50 MiB. Construction, including kind lookup and package statistics, took 81.0 ms. The 1,500 × 1,000-pixel gradient overview rendered in about 4.6 ms with a warmed allocator. A render centered on the smallest rectangle took 0.25 ms. These timings cover the file raster and label preparation. Display composition adds work. Center-point hit tests on a systematic sample matched the original file keys, and the containing folder ranges covered those rectangles.
- **Folder outline.** Expanding a folder with 24,000 children took 27.2 ms the first time and about 10.6 ms on subsequent expansions. Collapse took 6.3 ms initially and about 6.0 ms on subsequent collapses. Revealing a file four levels down took 33.4 ms and reached its exact 4,096-byte row.
- **Cached reopen.** Two observations of an unchanged local test root took 3.9 ms and 20.6 ms for identity and event-stream validation. A recently written fixture also triggered conservative revalidation while macOS delivered its coalesced events. After nested writes and a rename, incremental refresh produced the same allocation and entry count as a fresh scan.
- **Trash.** Moving an isolated generated folder containing 4,041 entries took 164 ms. This included preparing the batch review, performing the system Trash operation, updating the index, and rendering the resulting 1,500 × 1,000-pixel map. It excludes the time a person spends reading the review. The same check verified that an unrelated hard link retained its allocation and that a replaced file stayed in place. This single local measurement depends on the volume and filesystem load.

## Trash review and filesystem permissions

On a mounted read-only test volume, the backend rejected selecting the root itself, all root rows, and all map tiles. Selecting a file covering 98% of the scanned bytes required explicit acknowledgment. A permitted subset reached the macOS Trash API, which refused both items and left the folder contents intact. A separate folder on a writable volume also stayed in place when its parent denied write access. Both refusals returned the affected path for Show in Finder. A confirmed batch on a writable test directory moved the two selected items and preserved their neighbor.

In the native review sheet, Return and Escape canceled. The table listed every selected root, and the large-selection checkbox enabled the Move to Trash button only after acknowledgment.

## What Disk Inventory X does

Inspection of the installed Disk Inventory X 1.3 executable with REA showed that it recursively loads filesystem items with Foundation metadata, including size and kind. It builds folder totals and refreshes file-kind statistics as part of opening a document. Its normal Trash path calls the native system Trash API, detaches the item from the model and walks the removed subtree to update file-kind statistics.

Its kind resolver caches the localized description of the uniform type, with the URL’s localized type description as a fallback. The statistics pass groups by that description and sums bytes and counts. Its package-contents option controls whether packages count as individual items or expose their contents. In the original legend the largest kinds receive the first palette colors. DiskSlop uses persistent type colors across scopes, keeps the file-level hit targets, and updates the header and kind highlight on hover. [Original Disk Inventory X screenshots](https://www.derlien.com/screenshots/index.html)

DiskSlop uses the same recoverable macOS Trash operation. Its scan batches directory metadata, and its removal bookkeeping updates ancestor totals and any affected hard-link owners from an index. Rendering and map rebuilding run off the main thread. The launch timings include the combined cost of those operations. [Disk Inventory X](https://www.derlien.com/)
