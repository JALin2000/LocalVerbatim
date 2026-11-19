#!/usr/bin/env python3
"""Fetch, verify, and stage the exact redistributable runtime artifacts.

The checked-in manifest is the trust input. No package resolution, sdist build,
user installation, or model download is involved in this preparation process.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.metadata
import json
from pathlib import Path
import posixpath
import re
import shutil
import subprocess
import tarfile
from urllib.parse import unquote, urlparse


SOURCE = Path(__file__).resolve().parents[1]
LOCK = SOURCE / "scripts/runtime-artifacts.json"


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def manifest():
    lock = json.loads(LOCK.read_text())
    if lock["schema_version"] != 1:
        raise SystemExit("Unsupported runtime manifest schema")
    if digest(SOURCE / "requirements.lock.txt") != lock["requirements_sha256"]:
        raise SystemExit("requirements.lock.txt differs from the reviewed artifact manifest")
    expected = dict(line.split("==") for line in (SOURCE / "requirements.lock.txt").read_text().splitlines() if line)
    actual = {item["name"]: item["version"] for item in lock["wheels"]}
    if actual != expected or len(lock["wheels"]) != len(expected):
        raise SystemExit("Artifact manifest does not contain exactly the pinned requirements")
    for artifact in [lock["python"], *lock["wheels"]]:
        url = urlparse(artifact["url"])
        official_python = url.netloc == "github.com" and url.path.startswith("/astral-sh/python-build-standalone/releases/download/")
        official_wheel = url.netloc == "files.pythonhosted.org" and url.path.startswith("/packages/")
        if url.scheme != "https" or not (official_python or official_wheel):
            raise SystemExit("Runtime artifacts must come from official Astral/PyPI sources")
        if unquote(url.path.rsplit("/", 1)[-1]) != artifact["filename"] or "/" in artifact["filename"]:
            raise SystemExit("Invalid artifact filename")
        if not re.fullmatch(r"[a-f0-9]{64}", artifact["sha256"]):
            raise SystemExit("Artifact must have an exact SHA-256 digest")
    return lock


def verified(path, artifact):
    return path.is_file() and digest(path) == artifact["sha256"] and (
        "size" not in artifact or path.stat().st_size == artifact["size"]
    )


def fetch(directory, lock):
    directory.mkdir(parents=True, exist_ok=True)

    def one(artifact):
        path = directory / artifact["filename"]
        if not verified(path, artifact):
            pending = path.with_name(path.name + ".partial")
            subprocess.run([
                "/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                "--proto", "=https", "--proto-redir", "=https", "--retry", "3",
                "--output", str(pending), artifact["url"],
            ], check=True)
            if not verified(pending, artifact):
                pending.unlink(missing_ok=True)
                raise SystemExit("SHA-256/size mismatch: " + artifact["filename"])
            pending.replace(path)
        return artifact["filename"]

    with ThreadPoolExecutor(max_workers=4) as executor:
        for filename in executor.map(one, [lock["python"], *lock["wheels"]]):
            print("Verified " + filename, flush=True)


def extract(directory, stage, lock):
    runtime = stage / "runtime"
    if runtime.exists():
        raise SystemExit("Refusing to overwrite existing runtime: " + str(runtime))
    for artifact in [lock["python"], *lock["wheels"]]:
        if not verified(directory / artifact["filename"], artifact):
            raise SystemExit("Missing or altered artifact: " + artifact["filename"])
    archive = directory / lock["python"]["filename"]
    with tarfile.open(archive) as handle:
        for member in handle:
            normalized = posixpath.normpath(member.name)
            if normalized != "python" and not normalized.startswith("python/"):
                raise SystemExit("Unexpected Python archive member: " + member.name)
            if member.isdev() or member.isfifo():
                raise SystemExit("Unsupported Python archive member: " + member.name)
            if member.issym() or member.islnk():
                target = member.linkname if member.islnk() else posixpath.join(posixpath.dirname(normalized), member.linkname)
                if not posixpath.normpath(target).startswith("python/"):
                    raise SystemExit("Python archive link escapes its directory: " + member.name)
    runtime.mkdir(parents=True)
    subprocess.run(["/usr/bin/tar", "-xzf", str(archive), "-C", str(runtime), "--strip-components", "1"], check=True)
    requirements = stage / "requirements.hashed.txt"
    requirements.write_text("".join(
        f"{item['name']}=={item['version']} --hash=sha256:{item['sha256']}\n"
        for item in lock["wheels"]
    ))


def clean_bytecode(runtime):
    for path in runtime.rglob("*.pyc"):
        path.unlink()
    for path in sorted(runtime.rglob("__pycache__"), reverse=True):
        shutil.rmtree(path)


def finalize(runtime, lock):
    site = runtime / "lib/python3.13/site-packages"
    # This bundle supports the app's Qwen3-ASR/mono-16-kHz array path, not the
    # full MLX Audio SDK. Preserve upstream METADATA, including its wider SciPy
    # requirement; verify_bundled_runtime.py checks that exact documented gap.
    for excluded in lock["application_scope"]["excluded_distributions"]:
        for relative in excluded["paths"]:
            shutil.rmtree(runtime / relative, ignore_errors=True)
    # pip is a preparation tool, not an application dependency. ensurepip embeds
    # another pip wheel; exclude both while retaining the CPython license.
    for pattern in ("pip", "pip-*.dist-info"):
        for path in site.glob(pattern):
            shutil.rmtree(path)
    shutil.rmtree(runtime / "lib/python3.13/ensurepip", ignore_errors=True)
    for path in (runtime / "bin").glob("pip*"):
        path.unlink()
    # Test fixtures (including SciPy's WAV samples) and unused Tcl/Tk GUI
    # components are not part of this app. Keep any standalone license notices
    # even when their containing component is removed.
    for pattern in lock["pruning"]["remove_relative_globs"]:
        for path in sorted(runtime.glob(pattern), reverse=True):
            if path.is_dir() and not path.is_symlink():
                for notice in path.rglob("*"):
                    if notice.is_file() and notice.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")):
                        target = runtime / "removed-component-notices" / notice.relative_to(runtime)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(notice, target)
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
    for directory, relative_python in ((runtime / "bin", "python3.13"), (site / "bin", "../../../../bin/python3.13")):
        for path in directory.glob("*"):
            if path.is_symlink() or not path.is_file():
                continue
            data = path.read_bytes()
            first_line = data.split(b"\n", 1)[0]
            if first_line.startswith(b"#!") and b"python" in first_line:
                body = data.split(b"\n", 1)[1]
                launcher = (
                    "#!/bin/sh\n"
                    "'''exec' \"$(dirname -- \"$(realpath -- \"$0\")\")/" + relative_python + "\" \"$0\" \"$@\"\n"
                    "' '''\n"
                )
                path.write_bytes(launcher.encode() + body)
    # Installer provenance references local preparation paths; the public lock
    # supplies equivalent, reproducible provenance without those private paths.
    for metadata in site.glob("*.dist-info"):
        for name in ("direct_url.json", "uv_cache.json"):
            (metadata / name).unlink(missing_ok=True)
    clean_bytecode(runtime)
    actual = {dist.metadata["Name"].lower().replace("_", "-"): dist.version
              for dist in importlib.metadata.distributions(path=[str(site)])}
    excluded_names = {item["name"] for item in lock["application_scope"]["excluded_distributions"]}
    expected = {item["name"]: item["version"] for item in lock["wheels"] if item["name"] not in excluded_names}
    if actual != expected:
        raise SystemExit("Installed package versions differ from runtime lock: " + repr(actual))
    for path in runtime.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(runtime):
            raise SystemExit("External runtime symlink: " + str(path))
    (runtime / "runtime-artifacts.json").write_bytes(LOCK.read_bytes())
    print("Finalized exact CPython " + lock["python"]["version"] + " with " + str(len(actual)) + " pinned packages")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("validate", "fetch", "extract", "finalize", "clean-bytecode"))
    parser.add_argument("stage", type=Path)
    parser.add_argument("--downloads", type=Path)
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args()
    stage = args.stage.resolve()
    downloads = (args.downloads or stage / "downloads").resolve()
    cache = (args.cache or stage / "uv-cache").resolve()
    if any(path.is_relative_to(SOURCE) for path in (stage, downloads, cache)):
        raise SystemExit("Runtime preparation and downloads must be outside the source checkout")
    lock = manifest()
    if args.operation == "validate":
        return
    elif args.operation == "fetch":
        fetch(downloads, lock)
    elif args.operation == "extract":
        extract(downloads, stage, lock)
    elif args.operation == "clean-bytecode":
        clean_bytecode(stage / "runtime")
    else:
        finalize(stage / "runtime", lock)


if __name__ == "__main__":
    main()
