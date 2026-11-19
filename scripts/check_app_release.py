#!/usr/bin/env python3
"""Audit a weight-free macOS app for accidental local data before distribution.

Does not sign, modify, launch or upload the app. Signature/notarization checks
are separate. This is a guardrail, not a comprehensive secret/security audit.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re


SOURCE_ROOT = Path(__file__).resolve().parents[1]

FORBIDDEN_DIRS = {
    'Recordings', 'Diagnostics', '.git', '.venv', '__pycache__', '.localverbatim',
    '.pytest_cache', '.mypy_cache', 'node_modules',
}
FORBIDDEN_SUFFIXES = {
    '.wav', '.m4a', '.mp3', '.mp4', '.mov', '.flac', '.caf', '.pyc',
    '.p12', '.p8', '.key', '.mobileprovision', '.provisionprofile', '.log',
}
PRIVATE_NAMES = {'settings.json', 'preferences.json', 'migration.json', '.DS_Store',
                 'direct_url.json', 'pyvenv.cfg'}
SECRET_PATTERNS = {
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'GitHub credential': re.compile(rb'(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})(?![A-Za-z0-9_])'),
    'Hugging Face credential': re.compile(rb'(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{30,}(?![A-Za-z0-9_])'),
    'API credential': re.compile(rb'(?<![A-Za-z0-9_])sk-[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_])'),
}


def audit(app, private_markers=()):
    try:
        app = app.resolve(strict=True)
    except (OSError, RuntimeError):
        return {'status': 'failed', 'problems': ['Cannot resolve app directory']}
    problems = []
    files = []
    seen = set()

    def problem(path, message):
        item = f'{path}: {message}'
        if item not in seen:
            problems.append(item)
            seen.add(item)

    if not app.is_dir() or app.suffix != '.app':
        return {'status': 'failed', 'problems': ['Expected an existing .app directory']}
    contents = app / 'Contents'
    required = ['Info.plist', 'MacOS/LocalVerbatim', 'Resources/AppIcon.icns',
                'Resources/Support/engine/worker.py', 'Resources/Support/engine/manage_model.py',
                'Resources/Support/engine/model-manifest.json', 'Resources/Support/runtime/bin/python',
                'Resources/Support/runtime-artifacts.json', 'Resources/Legal/LICENSE',
                'Resources/Legal/NOTICE', 'Resources/Legal/THIRD_PARTY_NOTICES.md']
    for name in required:
        if not (contents / name).is_file():
            problem('Contents/' + name, 'missing required component')
    info = {}
    try:
        info = plistlib.loads((contents / 'Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'local.localscribe.meeting-recorder':
            problem('Contents/Info.plist', 'unexpected data-compatible bundle identifier')
        if info.get('LSMinimumSystemVersion') != '15.0':
            problem('Contents/Info.plist', 'unexpected minimum macOS version')
    except (OSError, ValueError, plistlib.InvalidFileException):
        problem('Contents/Info.plist', 'cannot read app metadata')

    for child in app.iterdir():
        if child.name != 'Contents':
            problem(child.name, 'unexpected app root component')
    allowed_contents = {'Info.plist', 'MacOS', 'Resources', '_CodeSignature', 'CodeResources'}
    for child in contents.iterdir() if contents.is_dir() else []:
        if child.name not in allowed_contents:
            problem(str(child.relative_to(app)), 'unexpected bundle component')
    markers = [str(Path.home()).encode()]
    markers += [value.encode() for value in private_markers if value.strip()]
    # Keep overlap large enough to detect markers spanning read boundaries.
    overlap = max([1024] + [len(value) for value in markers])
    for path in sorted(app.rglob('*')):
        relative = path.relative_to(app)
        label = relative.as_posix()
        if any(part in FORBIDDEN_DIRS for part in relative.parts):
            problem(label, 'local data or cache directory')
        # Apply naming/location policy to links too, before skipping their
        # contents. An internal link must not conceal weights or private files.
        if (path.suffix.lower() in FORBIDDEN_SUFFIXES or path.name in PRIVATE_NAMES
                or path.name.startswith(('.env', 'settings-backup-', 'preferences-backup-'))
                or path.name.endswith('.result.json')):
            problem(label, 'local data, credential, cache or recording artifact')
        if path.suffix.lower() == '.safetensors':
            problem(label, 'model weights in a first-run-download app')
        if relative.parts[:4] == ('Contents', 'Resources', 'Support', 'models'):
            # The ordinary empty models directory is intentional. Its children,
            # and a symlink or regular file in its place, are not release inputs.
            if len(relative.parts) > 4 or path.is_symlink() or not path.is_dir():
                problem(label, 'weights/data in a first-run-download app')
        if path.is_symlink():
            try:
                target = path.resolve(strict=True)
            except (OSError, RuntimeError):
                problem(label, 'broken or cyclic symlink')
            else:
                if not target.is_relative_to(app):
                    problem(label, 'symlink escapes the app')
            continue
        if not path.is_file():
            continue
        digest = hashlib.sha256()
        previous = b''
        with path.open('rb') as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
                window = previous + block
                if any(marker in window for marker in markers):
                    problem(label, 'private build path or supplied private marker (value omitted)')
                for kind, pattern in SECRET_PATTERNS.items():
                    if pattern.search(window):
                        problem(label, f'possible {kind} (value omitted)')
                previous = window[-overlap:]
        files.append({'path': label, 'bytes': path.stat().st_size, 'sha256': digest.hexdigest()})
    return {
        'status': 'failed' if problems else 'passed', 'app': app.name,
        'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
        'files_checked': len(files), 'total_bytes': sum(f['bytes'] for f in files),
        'problems': problems, 'files': files,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--private-markers', type=Path,
                        help='Private local UTF-8 file, one sensitive identity/path per line; never commit it')
    parser.add_argument('--report', type=Path, help='Save full hashes outside the app/source directory')
    args = parser.parse_args()
    if args.report:
        try:
            report = args.report.resolve()
            if report.is_relative_to(args.app.resolve()) or report.is_relative_to(SOURCE_ROOT):
                parser.error('Report must be outside the app and source directory')
        except (OSError, RuntimeError):
            parser.error('Cannot resolve report destination')
    markers = args.private_markers.read_text().splitlines() if args.private_markers else []
    result = audit(args.app, markers)
    if args.report:
        args.report.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    summary = {k: v for k, v in result.items() if k != 'files'}
    summary['problem_count'] = len(result['problems'])
    summary['problems'] = result['problems'][:50]
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return result['status'] != 'passed'


if __name__ == '__main__':
    raise SystemExit(main())
