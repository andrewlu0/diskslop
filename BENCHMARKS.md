# Performance

Measured on an Apple M4 Pro running macOS 27.0.1. The tests used the local APFS volume with a warm filesystem cache. Startup, command-line scanning, rendering, and moving to Trash were timed separately.

## Opening a document

On a generated tree containing **50,048 entries** across 128 groups and six subfolders per group, opening a fresh DiskTally window took a median **0.524 s**. Disk Inventory X 1.3 took **5.493 s**, a **10.5×** difference. Each run launched a new process. Both apps had to show a document window with the requested name and a populated native outline with a nonzero-height visible row. DiskTally additionally had to report a completed file raster. The timer included launch and accessibility polling. Single warm-up per app, followed by three alternating measured launches.

| Application | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| DiskTally, native Apple silicon | 0.495 s | 0.524 s | 0.537 s |
| Disk Inventory X 1.3, Intel under Rosetta | 5.677 s | 5.493 s | 5.411 s |

## Scanning

Median total command runtime in seconds. One warm-up and seven interleaved runs per tool and tree. DiskTally, macOS du and dua returned identical allocated-byte totals on all three inputs. The runs shared an active desktop, so the small timing differences are sensitive to system load.

| Tree | Entries | DiskTally | macOS du | dua 3.0.3 | szt 1.0.0 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Nested generated tree | 50,048 | 0.0376 | 0.1582 | 0.0563 | 0.0331 |
| One wide directory | 24,000 | 0.0364 | 0.0569 | 0.0836 | 0.0354 |
| Installed Xcode bundle | 167,225 | 0.6568 | 4.3234 | 1.2305 | 0.5286 |

Use `python3 bench.py /path/to/tree` after building. Optional `--dua` and `--szt` arguments take paths to those tools. The script times summaries and prints individual runs. Cold disks, network shares, and full-volume scans have different performance characteristics. [dua](https://github.com/Byron/dua-cli)

## Interaction

- **Treemap.** The Xcode tree had 137,232 file shapes, including 11,205 zero-allocation entries. Their areas summed to the full map within floating-point tolerance. The geometry used 14.34 MiB and took 33.0 ms to construct. A 1,500 × 1,000-pixel overview rendered in 10.94 ms at the median. A render centered on the smallest rectangle took 0.41 ms. These timings cover the file raster and label preparation. Display composition adds work. Center-point hit tests on a systematic sample matched the original file keys, and the containing folder ranges covered those rectangles.
- **Folder outline.** Expanding a folder with 24,000 children took 19.4 ms the first time and 8.3 ms on subsequent expansions. Collapse took 6.0 ms initially and 5.8 ms on subsequent collapses. Revealing a file four levels down took 22.4 ms and reached its exact 4,096-byte row.
- **Cached reopen.** For an unchanged local test root, identity and event-stream validation took 3.9 ms in one observation. After nested writes and a rename, incremental refresh produced the same allocation and entry count as a fresh scan.
- **Trash.** An isolated generated folder containing 4,041 entries moved to the macOS Trash in 106 ms, including refreshing the index and preparing the result. This single local observation used the earlier map implementation. Trash processing also preserved allocated totals across hard links and rejected a file replaced after the scan. Finder and filesystem latency can vary by volume.

## Trash review and filesystem permissions

On a mounted read-only test volume, the backend rejected selecting the root itself, all root rows, and all map tiles. Selecting a file covering 98% of the scanned bytes required explicit acknowledgment. A permitted subset reached the macOS Trash API, which refused both items and left the folder contents intact. A separate folder on a writable volume also stayed in place when its parent denied write access. Both refusals returned the affected path for Show in Finder. A confirmed batch on a writable test directory moved the two selected items and preserved their neighbor.

In the native review sheet, Return and Escape canceled. The table listed every selected root, and the large-selection checkbox enabled the Move to Trash button only after acknowledgment.

## What Disk Inventory X does

Inspection of the installed Disk Inventory X 1.3 executable with REA showed that it recursively loads filesystem items with Foundation metadata, including size and kind. It builds folder totals and refreshes file-kind statistics as part of opening a document. Its normal Trash path calls the native system Trash API, detaches the item from the model and walks the removed subtree to update file-kind statistics.

DiskTally uses the same recoverable macOS Trash operation. Its scan batches directory metadata, and its removal bookkeeping updates ancestor totals and any affected hard-link owners from an index. Rendering and map rebuilding run off the main thread. These are observed implementation differences; the total launch timings above do not isolate the cost of each one. [Disk Inventory X](https://www.derlien.com/)
