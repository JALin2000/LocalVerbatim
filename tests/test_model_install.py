import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import types

spec = importlib.util.spec_from_file_location('manage_model', Path(__file__).parents[1] / 'engine/manage_model.py')
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class ModelInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'; self.source.mkdir()
        self.destination = self.root / 'destination'
        self.files = {'config.json': b'{"model_type":"qwen3_asr"}', 'model.safetensors': b'model fixture' * 100}
        for name, data in self.files.items(): (self.source / name).write_bytes(data)
        self.manifest = {'repository': 'example/model', 'revision': 'pinned', 'directory': 'model', 'files': {
            n: {'size': len(v), 'sha256': hashlib.sha256(v).hexdigest()} for n, v in self.files.items()}}
        self.output = patch.object(manager, 'emit'); self.output.start()

    def tearDown(self):
        self.output.stop(); self.temp.cleanup()

    def test_verified_import_retains_source_and_publishes_all_files(self):
        target = manager.install(self.destination, self.manifest, self.source)
        for name, expected in self.files.items():
            self.assertEqual((target / name).read_bytes(), expected)
            self.assertEqual((self.source / name).read_bytes(), expected)

    def test_corrupt_model_is_never_published(self):
        path = self.source / 'model.safetensors'
        path.write_bytes(b'x' * len(self.files[path.name]))
        with self.assertRaisesRegex(ValueError, 'checksum'):
            manager.install(self.destination, self.manifest, self.source)
        self.assertFalse((self.destination / 'model').exists())

    def test_interrupted_download_resumes_same_stage_then_verifies(self):
        attempts = []
        def snapshot_download(repo, revision, local_dir, allow_patterns, token):
            attempts.append(local_dir)
            self.assertEqual((repo, revision, token), ('example/model', 'pinned', False))
            (local_dir / 'config.json').write_bytes(self.files['config.json'])
            if len(attempts) == 1:
                (local_dir / '.partial').write_bytes(b'partial')
                raise ConnectionError('temporary failure')
            self.assertTrue((local_dir / '.partial').exists())
            (local_dir / 'model.safetensors').write_bytes(self.files['model.safetensors'])
        with patch.dict('sys.modules', {'huggingface_hub': types.SimpleNamespace(snapshot_download=snapshot_download)}):
            with self.assertRaises(ConnectionError): manager.install(self.destination, self.manifest)
            self.assertFalse((self.destination / 'model').exists())
            target = manager.install(self.destination, self.manifest)
        self.assertEqual(attempts[0], attempts[1])
        self.assertEqual((target / 'model.safetensors').read_bytes(), self.files['model.safetensors'])
