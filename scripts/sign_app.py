#!/usr/bin/env python3
"""Sign a staged macOS app inside-out, or inspect/verify its signing plan.

No key or password is accepted. A public identity must already exist in Keychain.
The dry-run is read-only and does not claim that an identity or signature exists.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
APP_ENTITLEMENTS = SCRIPT_DIR / "entitlements/app.plist"
RUNTIME_ENTITLEMENTS = SCRIPT_DIR / "entitlements/runtime.plist"
THIN_MAGICS = {
    b"\xce\xfa\xed\xfe": "<", b"\xcf\xfa\xed\xfe": "<",
    b"\xfe\xed\xfa\xce": ">", b"\xfe\xed\xfa\xcf": ">",
}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True),
}
CODE_TYPES = {2, 6, 7, 8}  # MH_EXECUTE, MH_DYLIB, MH_DYLINKER, MH_BUNDLE
BUNDLE_SUFFIXES = {".app", ".framework", ".xpc", ".bundle", ".plugin", ".appex"}


def run(command, capture=False):
    return subprocess.run([str(arg) for arg in command], check=True, text=True,
                          capture_output=capture)


def macho_type(path):
    """Read headers, including universal binaries, without relying on extensions."""
    with path.open("rb") as stream:
        header = stream.read(16)
        magic = header[:4]
        if magic in THIN_MAGICS:
            if len(header) != 16:
                raise ValueError(f"Truncated Mach-O: {path}")
            return struct.unpack(THIN_MAGICS[magic] + "I", header[12:16])[0]
        if magic not in FAT_MAGICS:
            return None
        endian, wide = FAT_MAGICS[magic]
        if len(header) < 8:
            raise ValueError(f"Truncated universal header: {path}")
        count = struct.unpack(endian + "I", header[4:8])[0]
        if not 1 <= count <= 64:
            raise ValueError(f"Invalid universal architecture count: {path}")
        stream.seek(8)
        size = 32 if wide else 20
        records = stream.read(count * size)
        if len(records) != count * size:
            raise ValueError(f"Truncated universal architecture table: {path}")
        types = set()
        for index in range(count):
            record = records[index * size:(index + 1) * size]
            offset = struct.unpack(endian + ("Q" if wide else "I"), record[8:16] if wide else record[8:12])[0]
            stream.seek(offset)
            thin = stream.read(16)
            if len(thin) != 16 or thin[:4] not in THIN_MAGICS:
                raise ValueError(f"Invalid universal Mach-O slice: {path}")
            types.add(struct.unpack(THIN_MAGICS[thin[:4]] + "I", thin[12:16])[0])
        if len(types) != 1:
            raise ValueError(f"Mixed universal Mach-O file types: {path}")
        return types.pop()


def bundle_executable(bundle):
    candidates = [bundle / "Contents/Info.plist", bundle / "Resources/Info.plist", bundle / "Info.plist"]
    for info in candidates:
        if info.is_file():
            with info.open("rb") as stream:
                executable = plistlib.load(stream).get("CFBundleExecutable")
            if not isinstance(executable, str) or not executable or Path(executable).name != executable:
                continue
            for directory in (bundle / "Contents/MacOS", bundle):
                binary = directory / executable
                if binary.is_file():
                    return binary.resolve()
    return None


def signing_plan(app):
    app = Path(app)
    if app.is_symlink() or app.suffix != ".app" or not app.is_dir():
        raise ValueError("Expected an existing .app directory, not a symlink")
    app = app.resolve()
    main = bundle_executable(app)
    if main is None or not main.is_relative_to(app) or macho_type(main) != 2:
        raise ValueError("App must have a valid CFBundleExecutable and Mach-O executable")
    targets = []
    for directory, subdirs, filenames in os.walk(app, followlinks=False):
        for name in sorted(subdirs + filenames):
            path = Path(directory) / name
            if path.is_symlink():
                try:
                    resolved = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise ValueError(f"Broken or cyclic symlink: {path.relative_to(app)}") from error
                if not resolved.is_relative_to(app):
                    raise ValueError(f"Symlink escapes app: {path.relative_to(app)}")
                continue
            if path.is_dir():
                if path.suffix in BUNDLE_SUFFIXES:
                    binary = bundle_executable(path)
                    if binary is not None:
                        file_type = macho_type(binary)
                        if file_type not in CODE_TYPES:
                            raise ValueError(f"Unexpected nested bundle executable: {path.relative_to(app)}")
                        targets.append({"path": path, "kind": "bundle", "executable": file_type == 2})
                continue
            if not path.is_file():
                raise ValueError(f"Unsupported special file in app: {path.relative_to(app)}")
            file_type = macho_type(path)
            if file_type in CODE_TYPES and path != main:
                targets.append({"path": path, "kind": "macho", "executable": file_type == 2})
    targets.sort(key=lambda target: (-len(target["path"].parts), str(target["path"])))
    targets.append({"path": app, "kind": "app", "executable": True})
    return targets


def identity_from_keychain(identity):
    if not (re.fullmatch(r"[A-Fa-f0-9]{40}", identity) or identity.startswith("Developer ID Application: ")):
        raise ValueError("Public signing requires a Developer ID Application name or SHA-1 identity fingerprint")
    output = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], capture=True).stdout
    candidates = re.findall(r'\b([A-Fa-f0-9]{40})\s+"(Developer ID Application: [^"\n]+)"', output)
    matches = [(fingerprint, name) for fingerprint, name in candidates
               if identity.upper() == fingerprint.upper() or identity == name]
    if len(matches) != 1:
        raise ValueError("Expected exactly one valid matching Developer ID Application identity in Keychain")
    fingerprint, name = matches[0]
    team = re.search(r"\(([A-Z0-9]{10})\)$", name)
    if not team:
        raise ValueError("Cannot determine Team ID from signing identity")
    return fingerprint, team.group(1)


def sign_command(target, identity, hardened):
    command = ["/usr/bin/codesign", "--force", "--sign", identity]
    command += ["--timestamp"] if identity != "-" else ["--timestamp=none"]
    if hardened:
        command += ["--options", "runtime"]
    if target["executable"]:
        entitlements = APP_ENTITLEMENTS if target["kind"] == "app" else RUNTIME_ENTITLEMENTS
        command += ["--entitlements", str(entitlements), "--generate-entitlement-der"]
    command.append(str(target["path"]))
    return command


def signature_details(path):
    result = run(["/usr/bin/codesign", "--display", "--verbose=4", path], capture=True)
    return result.stdout + result.stderr


def check_developer_signature(path, require_runtime=True, expected_team=None):
    details = signature_details(path)
    team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", details, re.MULTILINE)
    if ("Authority=Developer ID Application:" not in details or not team or
            not re.search(r"^Timestamp=.+", details, re.MULTILINE)):
        raise ValueError(f"Not a timestamped Developer ID Application signature: {path}")
    if require_runtime and not re.search(r"flags=.*\bruntime\b", details):
        raise ValueError(f"Hardened Runtime is missing: {path}")
    if expected_team is not None and team.group(1) != expected_team:
        raise ValueError(f"Unexpected signing team: {path}")
    return team.group(1)


def verify_app(app, public=False, expected_team=None):
    targets = signing_plan(app)
    if public and expected_team is None:
        expected_team = check_developer_signature(Path(app))
    # Explicit verification covers native code in Resources too; --deep alone
    # does not reliably discover code placed outside standard nested-code paths.
    for target in targets:
        path = target["path"]
        run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", path], capture=True)
        if public:
            check_developer_signature(path, expected_team=expected_team)
            result = run(["/usr/bin/codesign", "--display", "--entitlements", ":-", path], capture=True)
            entitlements = plistlib.loads(result.stdout.encode()) if result.stdout.strip() else {}
            expected = {"com.apple.security.device.audio-input": True} if target["kind"] == "app" else {}
            if entitlements != expected:
                raise ValueError(f"Unexpected entitlements: {path}")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", app])
    return len(targets)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--identity", help="Existing Developer ID Application name or SHA-1 fingerprint")
    mode.add_argument("--adhoc", action="store_true", help="Local test only; not publicly trusted")
    mode.add_argument("--verify-only", action="store_true")
    parser.add_argument("--require-developer-id", action="store_true", help="With --verify-only, verify team, timestamp, runtime and entitlements")
    parser.add_argument("--hardened-runtime", action="store_true", help="Also enable Hardened Runtime in an ad-hoc test")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without signing or accessing Keychain")
    args = parser.parse_args()
    if not (args.identity or args.adhoc or args.verify_only):
        parser.error("Choose --identity, --adhoc or --verify-only explicitly")
    if args.require_developer_id and not args.verify_only:
        parser.error("--require-developer-id is only valid with --verify-only")
    if args.verify_only and args.dry_run:
        parser.error("--dry-run cannot verify signatures")
    if args.verify_only:
        count = verify_app(args.app, public=args.require_developer_id)
        print(f"Verified {count} signing targets ({'Developer ID' if args.require_developer_id else 'local'}).")
        return
    targets = signing_plan(args.app)
    identity = args.identity or "-"
    team = None
    if args.identity and not args.dry_run:
        identity, team = identity_from_keychain(args.identity)
    commands = [sign_command(target, identity, bool(args.identity or args.hardened_runtime)) for target in targets]
    if args.dry_run:
        print(json.dumps({"status": "dry-run; not signed or verified", "targets": commands}, indent=2))
        return
    for command in commands:
        run(command, capture=True)
    count = verify_app(args.app, public=bool(args.identity), expected_team=team)
    print(f"Signed and verified {count} targets ({'Developer ID; not yet notarized' if args.identity else 'ad-hoc; local test only'}).")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Signing failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        raise SystemExit(1)
