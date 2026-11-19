#!/usr/bin/env python3
"""Verify a staged Python runtime without loading a model or opening devices."""
import importlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    runtime = Path(sys.argv[1]).resolve()
    if Path(sys.prefix).resolve() != runtime or Path(sys.base_prefix).resolve() != runtime:
        raise SystemExit(f"Python is not self-contained: prefix={sys.prefix}, base_prefix={sys.base_prefix}")
    packages = {}
    for name in ["numpy", "scipy", "mlx.core", "mlx_audio.stt", "tokenizers", "sentencepiece", "psutil", "transformers", "miniaudio"]:
        module = importlib.import_module(name)
        origin = Path(module.__file__).resolve()
        if not origin.is_relative_to(runtime):
            raise SystemExit(f"External import: {name} -> {origin}")
        packages[name] = str(origin.relative_to(runtime))

    external_links = []
    external_libraries = []
    external_launchers = []
    native_count = 0
    native_magic = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
    for path in runtime.rglob("*"):
        if path.is_symlink():
            if not path.resolve().is_relative_to(runtime):
                external_links.append(str(path.relative_to(runtime)))
            continue
        if not path.is_file():
            continue
        with path.open("rb") as handle:
            prefix = handle.read(256)
        magic = prefix[:4]
        if prefix.startswith((b"#!/Users/", b"#!/opt/", b"#!/usr/local/")):
            external_launchers.append(str(path.relative_to(runtime)))
        if magic not in native_magic:
            continue
        native_count += 1
        result = subprocess.run(["/usr/bin/otool", "-L", str(path)], check=True, capture_output=True, text=True)
        identity = None
        if path.suffix == ".dylib":
            own_id = subprocess.run(["/usr/bin/otool", "-D", str(path)], check=True, capture_output=True, text=True)
            own_lines = own_id.stdout.splitlines()
            if len(own_lines) >= 2:
                identity = own_lines[1].strip()
        for line in result.stdout.splitlines():
            if not line.startswith("\t"):
                continue
            dependency = line.strip().split(" (", 1)[0]
            # otool -L includes LC_ID_DYLIB, the library's own install-name.
            # It is not a linked dependency and can contain a wheel build path.
            if identity is not None and dependency == identity:
                identity = None
                continue
            if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                external_libraries.append({"file": str(path.relative_to(runtime)), "dependency": dependency})
    if external_links or external_libraries or external_launchers:
        raise SystemExit(json.dumps({"external_symlinks": external_links, "external_libraries": external_libraries,
                                    "external_launchers": external_launchers}, indent=2))
    import mlx.core as mx
    sample = mx.array([1.0, 2.0, 3.0])
    mx.eval(sample + 1)
    print(json.dumps({"python": sys.version.split()[0], "runtime": str(runtime), "native_files_checked": native_count,
                      "imports": packages, "mlx_device": str(mx.default_device()), "status": "passed"}, indent=2))


if __name__ == "__main__":
    main()
