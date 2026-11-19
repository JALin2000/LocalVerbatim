#!/usr/bin/env python3
"""Preserve installed notices and inventory native binaries without importing packages.

Run after runtime pruning and before packaging. This evidence collector is not a
license decision engine; retain the reviewed component notes in LICENSES/README.md.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import re
import shutil
import subprocess

NOTICE_NAME = re.compile(r"^(LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT)(?:[._-].*)?$", re.I)
MACH_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}

def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    repo = args.repository.resolve()
    site = runtime / "lib/python3.13/site-packages"
    legal = repo / "LICENSES"
    packages = []
    source_inventory = json.loads((legal / "source-inventory.json").read_text())["packages"]
    normalize = lambda value: re.sub(r"[-_.]+", "-", value).lower()
    for dist in sorted(importlib.metadata.distributions(path=[str(site)]), key=lambda d: d.metadata["Name"].lower()):
        files = []
        for member in dist.files or []:
            path = Path(dist.locate_file(member))
            if not NOTICE_NAME.match(path.name) or not path.is_file():
                continue
            try:
                relative = path.resolve().relative_to(site)
            except ValueError:
                continue
            target = legal / "dependencies" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            files.append({"path": str(target.relative_to(repo)), "sha256": sha256(target)})
        if not files:
            matching = next((entry for entry in source_inventory
                             if normalize(entry["name"]) == normalize(dist.metadata["Name"])
                             and entry["version"] == dist.version), None)
            for notice in (matching or {}).get("license_files", []):
                target = repo / notice["path"]
                if target.is_file():
                    files.append({"path": notice["path"], "sha256": sha256(target),
                                  "basis": "Matching exact-version source archive; wheel omits license file"})
        packages.append({
            "name": dist.metadata["Name"], "version": dist.version,
            "declared_license": dist.metadata.get("License-Expression") or dist.metadata.get("License") or
                "; ".join(c for c in dist.metadata.get_all("Classifier", []) if c.startswith("License ::")),
            "preserved_license_files": sorted(f["path"] for f in files),
            "license_file_hashes": sorted(files, key=lambda f: f["path"]),
        })
    python_license = runtime / "lib/python3.13/LICENSE.txt"
    if python_license.is_file():
        (legal / "python").mkdir(exist_ok=True)
        shutil.copyfile(python_license, legal / "python/LICENSE.txt")
    inventory = {
        "basis": "Exact pruned application runtime, inspected without importing packages. Wheel source hashes are recorded in scripts/runtime-artifacts.json. Optional/development dependencies may be absent; this is not a full MLX Audio SDK environment.",
        "python_version": "3.13.15", "packages": packages,
    }
    (legal / "dependency-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    native = []
    for path in sorted(runtime.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in MACH_MAGICS:
                continue
        links = subprocess.check_output(["otool", "-L", str(path)], text=True)
        deps = sorted(set(line.strip().split(" (compatibility version")[0]
                          for line in links.splitlines() if line.startswith("\t")))
        for value in deps:
            if value.startswith(str(runtime)):
                raise SystemExit("Non-relocatable absolute runtime path in Mach-O library")
            if value.startswith("/Users/") or value.startswith("/private/"):
                raise SystemExit("Machine-specific path in Mach-O library")
        native.append({"path": str(path.relative_to(runtime)), "sha256_before_packaging": sha256(path),
                       "architectures": subprocess.check_output(["lipo", "-archs", str(path)], text=True).strip().split(),
                       "load_commands": deps})
    (legal / "native-binary-inventory.json").write_text(json.dumps({
        "basis": "Native Mach-O files and load commands in the pruned application runtime. Code signing can change byte hashes; final package integrity is verified separately. System framework/library paths describe platform dependencies, not redistributed files. Static components are described in the reviewed native-source inventory and README.",
        "files": native,
    }, indent=2) + "\n")
    print(f"Preserved notices for {len(packages)} distributions; inventoried {len(native)} native files")

if __name__ == "__main__":
    main()
