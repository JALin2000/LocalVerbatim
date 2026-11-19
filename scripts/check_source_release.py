#!/usr/bin/env python3
"""Check a clean source staging tree; never delete files or access the network."""
import argparse
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit


ROOT_FILES = {
    'README.md', 'README.zh-CN.md', 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md',
    'CHANGELOG.md', 'Package.swift', 'requirements.lock.txt', 'setup.command',
    '.gitignore', '.gitattributes', 'CONTRIBUTING.md', 'SECURITY.md',
}
ROOT_DIRS = {'Sources', 'Resources', 'engine', 'scripts', 'tests', 'docs', 'LICENSES', '.github'}
FORBIDDEN_DIRS = {
    'Recordings', 'Diagnostics', 'models', 'Models', 'runtime', '.venv',
    '__pycache__', '.build', '.build-cache', 'development-recordings', 'private-work',
    'cache', '.localverbatim', '.runtime-stage', 'dist',
}
FORBIDDEN_SUFFIXES = {
    '.wav', '.m4a', '.mp3', '.mp4', '.mov', '.dmg', '.zip', '.pyc',
    '.p12', '.p8', '.key', '.log', '.mobileprovision', '.provisionprofile',
}
PATTERNS = {
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'GitHub credential': re.compile(r'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}'),
    'Hugging Face credential': re.compile(r'hf_[A-Za-z0-9]{30,}'),
    'API credential': re.compile(r'sk-[A-Za-z0-9_-]{32,}'),
    'personal absolute path': re.compile(r'/Users/[A-Za-z0-9_.-]+/'),
}


def check(root):
    problems = []
    files = 0
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if '.git' in relative.parts:
            continue
        if path.is_symlink():
            problems.append(f'{relative}: symlinks are not allowed in a source release')
            continue
        if any(p in FORBIDDEN_DIRS or p.endswith('.app') for p in relative.parts):
            problems.append(f'{relative}: generated/private directory')
            continue
        if path.is_dir():
            if len(relative.parts) == 1 and relative.name not in ROOT_DIRS:
                problems.append(f'{relative}: unapproved root directory')
            continue
        files += 1
        if len(relative.parts) == 1 and relative.name not in ROOT_FILES:
            problems.append(f'{relative}: unapproved root file')
        if path.suffix.lower() in FORBIDDEN_SUFFIXES or path.name.startswith('.env') or path.name.endswith('.result.json'):
            problems.append(f'{relative}: data, credential or build artifact')
        content = path.read_bytes()
        try:
            text = content.decode('utf-8')
        except UnicodeDecodeError:
            if path.suffix.lower() not in {'.png', '.icns'} or relative.parts[0] not in {'Resources', 'scripts'}:
                problems.append(f'{relative}: unapproved binary file')
            continue
        for kind, pattern in PATTERNS.items():
            if pattern.search(text):
                problems.append(f'{relative}: possible {kind} (value omitted)')
        if path.suffix.lower() == '.md':
            links = re.findall(r'\]\(([^)]+)\)', text) + re.findall(r'<img\b[^>]*\bsrc="([^"]+)"', text)
            for target in links:
                target = target.strip().strip('<>')
                if urlsplit(target).scheme or target.startswith(('#', '//')):
                    continue
                target = unquote(target.split('#', 1)[0])
                resolved = (path.parent / target).resolve()
                if not resolved.is_relative_to(root.resolve()) or not resolved.exists():
                    problems.append(f'{relative}: missing/outside local link {target}')
    for required in ROOT_FILES:
        if not (root / required).is_file():
            problems.append(f'{required}: missing required source file')
    return {'files_checked': files, 'problems': problems, 'status': 'failed' if problems else 'passed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    if not args.directory.is_dir():
        parser.error('directory must exist')
    result = check(args.directory)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return bool(result['problems'])


if __name__ == '__main__':
    raise SystemExit(main())
