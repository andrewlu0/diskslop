#!/usr/bin/env python3
"""Measure complete warm-cache command invocations on the same filesystem tree."""
import argparse
import random
import shutil
import statistics
import subprocess
import time
from pathlib import Path


def measure(command, root):
    start = time.perf_counter()
    args = [str(root) if arg == "{root}" else arg for arg in command]
    result = subprocess.run(args, capture_output=True, check=True)
    return time.perf_counter() - start, result.stdout.decode(errors="replace")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("folders", type=Path, nargs="+")
    p.add_argument("--runs", type=int, default=7)
    p.add_argument("--dua", default=shutil.which("dua"))
    p.add_argument("--szt", default=shutil.which("szt"))
    args = p.parse_args()
    if args.runs < 1:
        p.error("--runs must be positive")
    cli = Path(__file__).resolve().parent / "target/release/disktally"
    tools = {"DiskTally": [str(cli), "--summary", "{root}"], "du": ["/usr/bin/du", "-skx", "{root}"]}
    if args.dua:
        # A second zero-size input prevents expansion of the root into separate output rows.
        tools["dua"] = [args.dua, "-x", "-f", "bytes", "aggregate", "--no-sort", "{root}", "/dev/null"]
    if args.szt:
        tools["szt"] = [args.szt, "--no-color", "-n", "1", "{root}"]
    rng = random.Random(73)
    for root in args.folders:
        root = root.resolve(strict=True)
        print(f"\n{root}", flush=True)
        for name, command in tools.items():
            _, output = measure(command, root)
            print(f"  {name}  {output.splitlines()[:2]}", flush=True)
        samples = {name: [] for name in tools}
        order = list(tools)
        for _ in range(args.runs):
            rng.shuffle(order)
            for name in order:
                seconds, _ = measure(tools[name], root)
                samples[name].append(seconds)
        for name, values in samples.items():
            individual = ", ".join(f"{v:.4f}" for v in values)
            print(f"  {name:<10} median {statistics.median(values):.4f} s   [{individual}]", flush=True)


if __name__ == "__main__":
    main()
