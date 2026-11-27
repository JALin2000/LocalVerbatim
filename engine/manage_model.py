"""Explicit, user-initiated model install. Never reads meeting audio or transcripts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import threading
import time

# Apply to both the app and command-line setup before importing Hugging Face.
# The public model needs no account, implicit saved token or telemetry.
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN'] = '1'


def emit(kind, **values):
    print(json.dumps({'type': kind, **values}), flush=True)


def verify(folder, manifest):
    total = sum(v['size'] for v in manifest['files'].values())
    finished = 0
    for name, expected in manifest['files'].items():
        path = folder / name
        if not path.is_file() or path.stat().st_size != expected['size']:
            raise ValueError(f'Model file missing or incomplete: {name}')
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block); finished += len(block)
                if finished % (32 * 1024 * 1024) < len(block):
                    emit('progress', phase='verifying', fraction=finished / total)
        if digest.hexdigest() != expected['sha256']:
            raise ValueError(f'Model checksum mismatch: {name}')
    emit('progress', phase='verifying', fraction=1)


def install(destination, manifest, source=None):
    target = destination / manifest['directory']
    if target.exists():
        verify(target, manifest)
        return target
    stage = destination / ('.download-' + manifest['directory'])
    stage.mkdir(parents=True, exist_ok=True)
    if source:
        for name in manifest['files']:
            emit('progress', phase='copying', fraction=0)
            shutil.copy2(source / name, stage / name)
    else:
        from huggingface_hub import snapshot_download
        done = threading.Event()
        total = sum(v['size'] for v in manifest['files'].values())
        def progress():
            while not done.wait(0.5):
                complete = sum((stage / n).stat().st_size for n in manifest['files'] if (stage / n).is_file())
                partial = sum(p.stat().st_size for p in stage.rglob('*.incomplete') if p.is_file())
                emit('progress', phase='downloading', fraction=min(0.99, (complete + partial) / total))
        threading.Thread(target=progress, daemon=True).start()
        try:
            snapshot_download(manifest['repository'], revision=manifest['revision'],
                              local_dir=stage, allow_patterns=list(manifest['files']), token=False)
        finally:
            done.set()
    verify(stage, manifest)
    # Publish only a completely verified model. A paused download remains in stage.
    stage.rename(target)
    return target


MANIFESTS = {'bf16': 'model-manifest.json', '8bit': 'model-manifest-8bit.json'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--import-folder', type=Path)
    parser.add_argument('--variant', choices=MANIFESTS, default='bf16')
    args = parser.parse_args()
    manifest = json.loads(Path(__file__).with_name(MANIFESTS[args.variant]).read_text())
    try:
        args.destination.mkdir(parents=True, exist_ok=True)
        target = install(args.destination, manifest, args.import_folder)
        emit('ready', path=str(target))
    except Exception as exc:
        emit('error', message=str(exc))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
