#!/usr/bin/env python3
"""Verify a staged Python runtime without loading a model or opening devices."""
import argparse
import importlib
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys


def verify_application_scope(runtime):
    """Check the intentional Qwen3-only bundle without changing upstream metadata."""
    from packaging.requirements import Requirement
    from packaging.utils import canonicalize_name
    lock = json.loads((runtime / "runtime-artifacts.json").read_text())
    scope = lock["application_scope"]
    excluded = {item["name"] for item in scope["excluded_distributions"]}
    expected = {item["name"]: item["version"] for item in lock["wheels"] if item["name"] not in excluded}
    distributions = list(importlib.metadata.distributions(path=[str(runtime / "lib/python3.13/site-packages")]))
    actual = {canonicalize_name(dist.metadata["Name"]): dist.version for dist in distributions}
    if actual != expected:
        raise SystemExit("Application package inventory differs from the reviewed runtime lock")
    gaps = []
    for dist in distributions:
        for value in dist.requires or []:
            requirement = Requirement(value)
            if requirement.marker and not requirement.marker.evaluate({"extra": ""}):
                continue
            dependency = canonicalize_name(requirement.name)
            if dependency not in actual:
                gaps.append({"distribution": canonicalize_name(dist.metadata["Name"]),
                             "dependency": dependency, "specifier": str(requirement.specifier)})
            elif actual[dependency] not in requirement.specifier:
                raise SystemExit("Incompatible runtime dependency: " + value)
    key = lambda item: (item["distribution"], item["dependency"], item["specifier"])
    if sorted(gaps, key=key) != sorted(scope["allowed_metadata_gaps"], key=key):
        raise SystemExit("Unexpected application dependency gap: " + json.dumps(gaps))
    for item in scope["excluded_distributions"]:
        if any((runtime / relative).exists() for relative in item["paths"]):
            raise SystemExit("Excluded SDK distribution is present: " + item["name"])
    if importlib.util.find_spec("scipy") is not None:
        raise SystemExit("The Qwen3-only application must not load an external SciPy installation")
    if (runtime / "lib/python3.13/site-packages/transformers/testing_utils.py").exists():
        raise SystemExit("Unused upstream test-support module was not pruned")
    return {"name": scope["name"], "installed_packages": len(actual), "declared_metadata_gaps": gaps}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("--device", choices=("gpu", "cpu"), default=os.environ.get("LOCALVERBATIM_VERIFY_DEVICE", "gpu"))
    args = parser.parse_args()
    if args.device not in ("gpu", "cpu"):
        parser.error("LOCALVERBATIM_VERIFY_DEVICE must be gpu or cpu")
    runtime = args.runtime.resolve()
    if Path(sys.prefix).resolve() != runtime or Path(sys.base_prefix).resolve() != runtime:
        raise SystemExit(f"Python is not self-contained: prefix={sys.prefix}, base_prefix={sys.base_prefix}")
    scope = verify_application_scope(runtime)
    # Selection is explicit. A build without access to Metal may fail while
    # importing the upstream MLX binary, even when CPU execution is requested;
    # that failure must remain visible rather than become an implicit pass.
    import mlx.core as mx
    mx.set_default_device(mx.cpu if args.device == "cpu" else mx.gpu)
    packages = {}
    for name in ["numpy", "mlx.core", "mlx_audio.stt", "mlx_audio.stt.models.qwen3_asr", "tokenizers", "sentencepiece", "psutil", "transformers", "miniaudio", "huggingface_hub", "huggingface_hub._snapshot_download"]:
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
            if any(name in dependency.lower() for name in ("libquadmath", "libgfortran", "libgcc", "/scipy/")):
                external_libraries.append({"file": str(path.relative_to(runtime)), "excluded_dependency": dependency})
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
    import numpy as np
    from transformers import WhisperFeatureExtractor
    # The application's worker supplies mono 16 kHz arrays, so Qwen3 feature
    # extraction needs neither MLX Audio's arbitrary-rate resampler nor SciPy.
    WhisperFeatureExtractor()(np.zeros(16000, dtype=np.float32), sampling_rate=16000, return_tensors="np")
    sample = mx.array([1.0, 2.0, 3.0])
    mx.eval(sample + 1)
    print(json.dumps({"python": sys.version.split()[0], "runtime": str(runtime), "native_files_checked": native_count,
                      "imports": packages, "application_scope": scope, "qwen3_feature_extraction": "passed",
                      "requested_device": args.device, "mlx_device": str(mx.default_device()), "status": "passed"}, indent=2))


if __name__ == "__main__":
    main()
