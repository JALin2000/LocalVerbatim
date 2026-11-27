from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('app_release', Path(__file__).parents[1] / 'scripts/check_app_release.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class AppReleaseAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.app = self.root / 'LocalVerbatim.app'
        self.contents = self.app / 'Contents'
        names = ['MacOS/LocalVerbatim', 'Resources/AppIcon.icns',
                 'Resources/Support/engine/worker.py', 'Resources/Support/engine/manage_model.py',
                 'Resources/Support/engine/model-manifest.json', 'Resources/Support/engine/model-manifest-8bit.json',
                 'Resources/Support/runtime/bin/python',
                 'Resources/Support/runtime-artifacts.json', 'Resources/Legal/LICENSE',
                 'Resources/Legal/NOTICE', 'Resources/Legal/THIRD_PARTY_NOTICES.md']
        for name in names:
            target = self.contents / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b'invented fixture')
        (self.contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'local.localscribe.meeting-recorder',
            'LSMinimumSystemVersion': '15.0', 'CFBundleShortVersionString': '0.0.0',
            'CFBundleVersion': '1',
        }))

    def tearDown(self):
        self.temp.cleanup()

    def test_clean_bundle_and_internal_symlink_pass_without_mutation(self):
        python = self.contents / 'Resources/Support/runtime/bin/python'
        python.rename(python.with_name('python3'))
        python.symlink_to('python3')
        result = checker.audit(self.app)
        self.assertEqual(result['status'], 'passed', result['problems'])
        self.assertTrue(python.is_symlink())
        self.assertEqual(python.read_bytes(), b'invented fixture')

    def test_model_implementation_code_is_not_confused_with_weights(self):
        path = self.contents / 'Resources/Support/runtime/lib/package/models/model.py'
        path.parent.mkdir(parents=True)
        path.write_text('# Invented implementation, not downloaded weights.\n')
        self.assertEqual(checker.audit(self.app)['status'], 'passed')

    def test_recording_model_and_escaping_link_are_rejected(self):
        for name in ['Resources/Support/Recordings/meeting.wav',
                     'Resources/Support/models/example/model.safetensors']:
            target = self.contents / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b'invented fixture')
        (self.contents / 'Resources/escape').symlink_to(self.root)
        result = checker.audit(self.app)
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('recording artifact' in p for p in result['problems']))
        self.assertTrue(any('weights/data' in p for p in result['problems']))
        self.assertTrue(any('escapes' in p for p in result['problems']))

    def test_unexpected_app_root_file_and_directory_are_rejected(self):
        (self.app / 'private-transcript.txt').write_text('Invented meeting minutes.')
        (self.app / 'private-notes').mkdir()
        result = checker.audit(self.app)
        self.assertEqual(result['status'], 'failed')
        self.assertIn('private-transcript.txt: unexpected app root component', result['problems'])
        self.assertIn('private-notes: unexpected app root component', result['problems'])

    def test_safetensors_rejected_outside_model_directory_but_bin_allowed(self):
        target = self.contents / 'Resources/Support/runtime/code-unit.bin'
        target.write_bytes(b'invented compiled code unit')
        self.assertEqual(checker.audit(self.app)['status'], 'passed')
        weights = target.with_name('weights.SAFETENSORS')
        weights.write_bytes(b'invented weight data')
        result = checker.audit(self.app)
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('weights.SAFETENSORS: model weights' in p for p in result['problems']))

    def test_model_and_private_file_symlinks_do_not_bypass_policy(self):
        models = self.contents / 'Resources/Support/models'
        models.mkdir()
        target = self.contents / 'Resources/Support/runtime/payload.txt'
        target.write_text('invented payload')
        # A normal empty model directory is part of the weight-free app layout.
        self.assertEqual(checker.audit(self.app)['status'], 'passed')
        (models / 'weights.bin').symlink_to('../runtime/payload.txt')
        (self.contents / 'Resources/settings.json').symlink_to('Support/runtime/payload.txt')
        result = checker.audit(self.app)
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('models/weights.bin: weights/data' in p for p in result['problems']))
        self.assertTrue(any('settings.json: local data' in p for p in result['problems']))
        (models / 'weights.bin').unlink()
        models.rmdir()
        models.symlink_to('runtime', target_is_directory=True)
        result = checker.audit(self.app)
        self.assertTrue(any('Support/models: weights/data' in p for p in result['problems']))

    def test_broken_and_cyclic_symlinks_return_failed_report(self):
        resources = self.contents / 'Resources'
        (resources / 'broken').symlink_to('does-not-exist')
        (resources / 'loop-a').symlink_to('loop-b')
        (resources / 'loop-b').symlink_to('loop-a')
        result = checker.audit(self.app)
        self.assertEqual(result['status'], 'failed')
        for name in ('broken', 'loop-a', 'loop-b'):
            self.assertIn(f'Contents/Resources/{name}: broken or cyclic symlink', result['problems'])

    def test_report_cannot_be_written_inside_app_or_source_through_alias(self):
        source = (self.root / 'source').resolve()
        source.mkdir()
        alias = self.root / 'source-alias'
        alias.symlink_to(source, target_is_directory=True)
        for report in (self.app / 'audit.json', source / 'audit.json', alias / 'audit.json'):
            with self.subTest(report=report):
                argv = ['check_app_release.py', str(self.app), '--report', str(report)]
                with patch.object(sys, 'argv', argv), patch.object(checker, 'SOURCE_ROOT', source):
                    with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                        checker.main()
                self.assertEqual(error.exception.code, 2)
                self.assertFalse(report.exists())
        report = self.root / 'audit.json'
        argv = ['check_app_release.py', str(self.app), '--report', str(report)]
        with patch.object(sys, 'argv', argv), patch.object(checker, 'SOURCE_ROOT', source):
            with redirect_stdout(io.StringIO()):
                self.assertFalse(checker.main())
        self.assertEqual(json.loads(report.read_text())['status'], 'passed')

    def test_private_marker_across_stream_boundary_is_redacted(self):
        marker = 'synthetic-private-identity'
        target = self.contents / 'MacOS/LocalVerbatim'
        target.write_bytes(b'x' * (1024 * 1024 - 8) + marker.encode() + b'end')
        result = checker.audit(self.app, [marker])
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('private marker' in p for p in result['problems']))
        self.assertNotIn(marker, str(result))


if __name__ == '__main__':
    unittest.main()
