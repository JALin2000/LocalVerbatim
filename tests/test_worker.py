"""Small input-contract tests; no model download or microphone access."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import wave


MODULE_PATH = Path(__file__).resolve().parents[1] / "engine" / "worker.py"
spec = importlib.util.spec_from_file_location("localverbatim_worker", MODULE_PATH)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class AudioInputContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "chunk.wav"

    def tearDown(self):
        self.temp.cleanup()

    def write_wav(self, raw, rate=16000, channels=1, width=2):
        with wave.open(str(self.path), "wb") as output:
            output.setframerate(rate)
            output.setnchannels(channels)
            output.setsampwidth(width)
            output.writeframes(raw)

    def test_pcm16_conversion_preserves_signed_range_and_sample_count(self):
        self.write_wav(struct.pack("<5h", -32768, -16384, 0, 16384, 32767))
        result = worker.read_audio(self.path)
        self.assertEqual(result.dtype.name, "float32")
        self.assertEqual(result.tolist(), [-1.0, -0.5, 0.0, 0.5, 32767 / 32768])

    def test_rejects_wrong_rate_and_stereo_instead_of_misinterpreting_audio(self):
        for rate, channels in ((48000, 1), (16000, 2)):
            with self.subTest(rate=rate, channels=channels):
                self.write_wav(b"\x00" * 32, rate=rate, channels=channels)
                with self.assertRaisesRegex(ValueError, "mono 16000"):
                    worker.read_audio(self.path)

    def test_rejects_8bit_pcm_instead_of_reading_as_int16(self):
        self.write_wav(b"\x80" * 100, width=1)
        with self.assertRaisesRegex(ValueError, "PCM16"):
            worker.read_audio(self.path)

    def test_duration_bound_is_checked_at_exact_boundary(self):
        self.write_wav(b"\x00\x00" * (21 * 16000))
        self.assertEqual(len(worker.read_audio(self.path)), 21 * 16000)
        self.write_wav(b"\x00\x00" * (21 * 16000 + 1))
        with self.assertRaisesRegex(ValueError, "21-second"):
            worker.read_audio(self.path)

    def test_empty_file_returns_empty_audio(self):
        self.write_wav(b"")
        self.assertEqual(len(worker.read_audio(self.path)), 0)

    def test_refinement_reads_exact_range_without_loading_full_recording(self):
        self.write_wav(struct.pack("<h", 100) * 16000 + struct.pack("<h", 200) * 16000)
        result = worker.read_refinement_audio(self.path, 16000, 16000)
        self.assertEqual(len(result), 16000)
        self.assertTrue((result == 200 / 32768).all())

    def test_refinement_enforces_bounds_and_rejects_invalid_ranges(self):
        self.write_wav(b"\x00\x00" * (31 * 16000))
        self.assertEqual(len(worker.read_refinement_audio(self.path, 16000, 30 * 16000)), 30 * 16000)
        for start, count in [(-1, 100), (0, 0), (0, 30 * 16000 + 1), (31 * 16000, 1), (True, 100), (0, 1.5)]:
            with self.subTest(start=start, count=count), self.assertRaises(ValueError):
                worker.read_refinement_audio(self.path, start, count)

    def test_missing_or_malformed_file_raises(self):
        with self.assertRaises(FileNotFoundError):
            worker.read_audio(self.path)
        self.path.write_bytes(b"invalid wav")
        with self.assertRaises(wave.Error):
            worker.read_audio(self.path)


class PhysicalFootprintTests(unittest.TestCase):
    def test_darwin_physical_footprint_is_readable_and_positive(self):
        self.assertGreater(worker.footprint(), 0)


class RecognitionQualityTests(unittest.TestCase):
    class FakeModel:
        def __init__(self, outputs):
            self.outputs = iter(outputs)
            self.calls = []

        def generate(self, data, **kwargs):
            from types import SimpleNamespace
            self.calls.append((len(data), kwargs))
            text, tokens = next(self.outputs)
            return SimpleNamespace(text=text, generation_tokens=tokens)

    def test_normal_repetitions_are_unchanged_without_retry(self):
        import numpy as np
        text = 'Okay, okay. 行行行，问题不大，问题不大。'
        model = self.FakeModel([(text, 30)])
        parts, quality = worker.recognize_guarded(model, np.ones(16000), '', {'hotwords': ['inventory']}, False, lambda: None)
        self.assertEqual(parts[0]['text'], text)
        self.assertIsNone(quality)
        self.assertEqual(len(model.calls), 1)

    def test_loop_retries_audio_without_prompt_and_preserves_failed_output(self):
        import numpy as np
        bad = 'Hello. ' + 'Okay. ' * 200
        good = 'Hello. 纸杯已经放好，午餐清单在桌上。'
        model = self.FakeModel([(bad, 768), (good, 40)])
        parts, quality = worker.recognize_guarded(model, np.ones(480000), '', {'system_prompt': 'context', 'hotwords': ['term']}, True, lambda: None)
        self.assertEqual(parts[0]['text'], good)
        self.assertEqual(model.calls[0][0], model.calls[1][0])
        self.assertNotIn('hotwords', model.calls[1][1])
        self.assertNotIn('system_prompt', model.calls[1][1])
        self.assertEqual(quality['attempts'][0]['text'], bad.strip())
        self.assertEqual(quality['status'], 'recovered')

    def test_non_english_phrase_loops_and_truncated_output_are_detected(self):
        self.assertEqual(worker.quality_problem('谢谢观看' * 30), 'repetition_loop')
        self.assertEqual(worker.quality_problem('unique words', 512, 512), 'token_budget_exhausted')
        self.assertIsNone(worker.quality_problem('好，好，好。Yes, yes, yes.'))

    def test_unrecoverable_loop_is_not_returned_as_a_success(self):
        import numpy as np
        bad = 'Okay. ' * 200
        model = self.FakeModel([(bad, 512), (bad, 512), (bad, 384)])
        with self.assertRaises(worker.RecognitionQualityError) as error:
            worker.recognize_guarded(model, np.ones(16000), '', {}, False, lambda: None)
        self.assertEqual(error.exception.quality['status'], 'failed')
        self.assertEqual(len(error.exception.quality['attempts']), 3)
        self.assertEqual(model.calls[-1][1]['repetition_penalty'], 1.1)

    def test_short_retry_covers_all_audio_and_preserves_real_words(self):
        import numpy as np
        data = np.full(30 * 16000, 0.2, dtype=np.float32)
        spans = worker.retry_spans(data)
        np.testing.assert_array_equal(np.concatenate([data[a:b] for a, b in spans]), data)
        self.assertTrue(all(0 < b - a <= 12 * 16000 for a, b in spans))
        bad = 'Okay. ' * 100
        model = self.FakeModel([(bad, 768), (bad, 768), ('第一段', 5), ('second part', 6), ('最后一段', 5)])
        parts, quality = worker.recognize_guarded(model, data, '', {}, True, lambda: None)
        self.assertEqual([p['text'] for p in parts], ['第一段', 'second part', '最后一段'])
        self.assertEqual([(p['start'], p['end']) for p in parts], [(0, 10), (10, 20), (20, 30)])
        self.assertEqual(quality['status'], 'recovered')


class PauseBoundaryTests(unittest.TestCase):
    def test_brief_interjections_keep_following_sentence_context(self):
        import numpy as np
        audio = np.r_[np.full(9600, .1), np.zeros(16000),
                      np.full(12800, .1), np.zeros(16000),
                      np.full(96000, .1)].astype(np.float32)
        self.assertEqual(worker.recognition_spans(audio), [(0, len(audio))])

    def test_language_switch_pause_splits_but_preserves_every_sample(self):
        import numpy as np
        audio = np.r_[np.zeros(32000), np.full(48000, .1),
                      np.zeros(16000), np.full(32000, .05), np.zeros(16000)].astype(np.float32)
        spans = worker.recognition_spans(audio)
        self.assertEqual(len(spans), 2)
        self.assertEqual(spans[0][1], 88000)
        self.assertEqual(spans[0][0], 0)
        self.assertEqual(spans[1][1], len(audio))
        np.testing.assert_array_equal(np.concatenate([audio[start:end] for start, end in spans]), audio)

    def test_short_pause_does_not_fragment_a_sentence(self):
        import numpy as np
        audio = np.r_[np.full(32000, .1), np.zeros(4800), np.full(32000, .1)].astype(np.float32)
        self.assertEqual(worker.recognition_spans(audio), [(0, len(audio))])

    def test_leading_and_trailing_silence_do_not_make_empty_utterances(self):
        import numpy as np
        audio = np.r_[np.zeros(48000), np.full(32000, .1), np.zeros(96000)].astype(np.float32)
        self.assertEqual(worker.recognition_spans(audio), [(0, len(audio))])

    def test_quiet_speech_is_not_treated_as_the_gap(self):
        import numpy as np
        audio = np.r_[np.full(32000, .0008), np.zeros(16000), np.full(32000, .0006)].astype(np.float32)
        self.assertEqual(worker.recognition_spans(audio), [(0, 40000), (40000, len(audio))])


class VocabularyTests(unittest.TestCase):
    def test_empty_hints_preserve_default_model_behavior(self):
        self.assertEqual(worker.parse_recognition_hints({}), {})
        self.assertEqual(worker.parse_recognition_hints({"vocabulary": " , \n", "context": "  "}), {})

    def test_multilingual_terms_preserve_phrases_and_deduplicate(self):
        result = worker.parse_recognition_hints({"vocabulary": "API, CSV导出\ninventory，project plan;api、货架号", "context": " 库存计划例会 "})
        self.assertEqual(result["hotwords"], ["API", "CSV导出", "inventory", "project plan", "货架号"])
        self.assertEqual(result["system_prompt"], "库存计划例会")

    def test_hint_sizes_are_bounded(self):
        terms = ",".join("term" + str(index) for index in range(100))
        result = worker.parse_recognition_hints({"vocabulary": terms, "context": "x" * 2000})
        self.assertEqual(len(result["hotwords"]), 40)
        self.assertEqual(len(result["system_prompt"]), 1000)
        self.assertEqual(len(worker.parse_recognition_hints({"vocabulary": "x" * 5000})["hotwords"][0]), 80)

    def test_invalid_hint_shapes_are_rejected(self):
        with self.assertRaises(ValueError):
            worker.parse_recognition_hints({"vocabulary": ["API"]})


if __name__ == "__main__":
    unittest.main()
