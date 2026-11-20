#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess


root = Path(__file__).resolve().parents[1]


def license_text(path):
    return "\n".join(line.rstrip() for line in path.read_text(encoding="utf-8").splitlines()).strip()


packages = {}
for architecture in ("aarch64", "x86_64"):
    metadata = subprocess.check_output([
        "cargo", "metadata", "--locked", "--offline", "--format-version", "1",
        "--filter-platform", architecture + "-apple-darwin",
    ], cwd=root)
    for package in json.loads(metadata)["packages"]:
        if package["source"]:
            packages[package["id"]] = package

sections = {}
for package in sorted(packages.values(), key=lambda item: (item["name"], item["version"])):
    folder = Path(package["manifest_path"]).parent
    files = sorted(path for path in folder.iterdir() if path.is_file() and
                   path.name.upper().startswith(("LICENSE", "COPYING", "COPYRIGHT", "NOTICE")))
    if package["name"] == "zstd-sys":
        files.append(folder / "zstd/LICENSE")
    if not files:
        raise SystemExit(f"Missing license text for {package['id']}")
    for path in files:
        notice = license_text(path)
        label = f"{package['name']} {package['version']} — {path.relative_to(folder)}"
        sections.setdefault(notice, []).append(label)

sparkle = Path(subprocess.check_output([root / "scripts/sparkle.sh"], cwd=root, text=True).strip())
print("""DiskSlop third-party notices

Nucleo Icons
Copyright © Nucleo
https://nucleoapp.com/
Redistribution of icons is prohibited.
Icons are restricted for use only within the product they are bundled with.
https://nucleoapp.com/license

Rust library copyright information
https://github.com/rust-lang/rust/blob/main/COPYRIGHT

""" + sparkle.name + "\nhttps://sparkle-project.org/\n")
print(license_text(sparkle / "LICENSE"))
for notice, labels in sections.items():
    print("\n" + "=" * 72 + "\n" + "\n".join(labels) + "\n\n" + notice)
