"""Offline-only, one-model / one-chunk-at-a-time JSON-lines ASR worker."""
import argparse
import contextlib
import ctypes
import json
import os
from pathlib import Path
import re
import sys
import threading
import time
import wave

# Set before importing any Hugging Face code. Download is a separate explicit step.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"
OUTPUT = sys.stdout
LOCK = threading.Lock()
peak = 0


def emit(kind, **kwargs):
    with LOCK:
        OUTPUT.write(json.dumps({"type": kind, **kwargs}, ensure_ascii=False) + "\n")
        OUTPUT.flush()


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16),
                ("values", ctypes.c_uint64 * 18)]


def footprint():
    """Darwin rusage_info_v2. Includes compressed and Metal-accounted memory."""
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    result = Usage()
    if lib.proc_pid_rusage(os.getpid(), 2, ctypes.byref(result)) != 0:
        raise RuntimeError("Cannot read macOS physical footprint; refusing unmonitored ASR")
    return int(result.values[7])


def memory_limit():
    # Both processes use the same installed RAM value. Standalone worker tests
    # and CLI callers derive it from the OS when the app does not supply it.
    configured = os.environ.get("LOCALVERBATIM_RAM_BYTES")
    ram = int(configured) if configured is not None else os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
    if ram <= 0:
        raise RuntimeError("Cannot determine installed RAM")
    return ram * 9 // 10


def monitor(limit):
    global peak
    next_report = 0
    while True:
        try:
            current = footprint()
            peak = max(peak, current)
            if current >= limit:
                emit("error", message="识别进程已达到本机 RAM 的 90%，转写已停止。已保存的录音可以稍后重试。", fatal=True)
                os._exit(75)
            if time.monotonic() >= next_report:
                emit("memory", bytes=current, peak=peak)
                next_report = time.monotonic() + 1
        except Exception as exc:
            emit("error", message=str(exc), fatal=True)
            os._exit(76)
        time.sleep(0.05)


def read_audio(path):
    import numpy as np
    with wave.open(str(path), "rb") as f:
        if f.getframerate() != 16000 or f.getnchannels() != 1:
            raise ValueError("Expected mono 16000 Hz WAV")
        if f.getnframes() > 21 * 16000:
            raise ValueError("Audio chunk exceeds 21-second memory bound")
        width = f.getsampwidth()
        raw = f.readframes(f.getnframes())
    if width != 2:
        raise ValueError("Expected PCM16 WAV")
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def recognition_spans(data):
    """Split at substantial internal pauses without dropping any samples.

    Qwen can stop after the first language or translate the second language
    when two utterances share one capture window. Independent pause-delimited
    decoding lets it detect each utterance's language. This is a bounded energy
    splitter, not speaker diarization or a trained voice activity detector.
    """
    import numpy as np
    length = len(data)
    if not length:
        return []
    frame = 320  # 20 ms at 16 kHz
    count = length // frame
    if count < 50:
        return [(0, length)]
    rms = np.sqrt(np.mean(data[:count * frame].reshape(count, frame) ** 2, axis=1))
    # Adapt to quiet speech; only split in gaps well below the voiced energy.
    threshold = max(0.00002, min(0.002, float(np.percentile(rms, 90)) * 0.05))
    quiet = rms < threshold
    changes = np.diff(np.r_[False, quiet, False].astype(np.int8))
    starts = np.flatnonzero(changes == 1)
    ends = np.flatnonzero(changes == -1)
    boundaries = [0]
    for start, end in zip(starts, ends):
        # Leading/trailing silence remains attached to its utterance. Require
        # 450 ms of quiet plus at least one second of audio on each side.
        if start == 0 or end == count or (end - start) * frame < 7200:
            continue
        midpoint = int((start + end) * frame // 2)
        if midpoint - boundaries[-1] >= 16000 and length - midpoint >= 16000:
            boundaries.append(midpoint)
    boundaries.append(length)
    # A one-second interjection decoded alone can become a spurious foreign
    # phrase. Retain context by requiring two seconds of speech-like energy
    # on both sides. This only merges spans; it never removes audio. Longer
    # English/Mandarin utterances still retain their language-switch boundary.
    cumulative = np.r_[0, np.cumsum(rms >= threshold)]
    guarded = [0]
    for end in boundaries[1:-1]:
        at = min(count, end // frame)
        previous = min(count, guarded[-1] // frame)
        if cumulative[at] - cumulative[previous] >= 100 and cumulative[-1] - cumulative[at] >= 100:
            guarded.append(end)
    guarded.append(length)
    return list(zip(guarded, guarded[1:]))


def read_refinement_audio(path, start_frame, frame_count):
    """Read only the requested bounded range from a finalized archive."""
    import numpy as np
    if type(start_frame) is not int or type(frame_count) is not int:
        raise ValueError("Refinement frame bounds must be integers")
    if start_frame < 0 or not 0 < frame_count <= 30 * 16000:
        raise ValueError("Refinement range exceeds the 30-second memory bound")
    with wave.open(str(path), "rb") as f:
        if (f.getframerate(), f.getnchannels(), f.getsampwidth()) != (16000, 1, 2):
            raise ValueError("Expected mono 16000 Hz PCM16 WAV")
        if start_frame + frame_count > f.getnframes():
            raise ValueError("Refinement range exceeds the recording")
        f.setpos(start_frame)
        raw = f.readframes(frame_count)
    if len(raw) != frame_count * 2:
        raise ValueError("Truncated refinement audio")
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


def parse_recognition_hints(job):
    """Bound optional meeting vocabulary/background before model prompting."""
    vocabulary = job.get("vocabulary") or ""
    context = job.get("context") or ""
    if not isinstance(vocabulary, str) or not isinstance(context, str):
        raise ValueError("Meeting vocabulary and context must be text")
    terms, seen = [], set()
    for term in re.split(r"[,，;；、\n\r]+", vocabulary[:2000]):
        term = term.strip()[:80]
        key = term.casefold()
        if term and key not in seen:
            terms.append(term)
            seen.add(key)
            if len(terms) == 40:
                break
    context = context[:1000].strip()
    hints = {}
    if terms:
        hints["hotwords"] = terms
    if context:
        hints["system_prompt"] = context
    return hints


def quality_problem(text, generated_tokens=None, budget=None):
    """Detect a decoder loop, not ordinary conversational repetition."""
    if isinstance(generated_tokens, int) and budget and generated_tokens >= budget:
        return "token_budget_exhausted"
    tokens = re.findall(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)?|[\u3400-\u9fff]|[^\W_]", text.casefold())[:4096]
    if len(tokens) < 24:
        return None
    for width in range(1, min(8, len(tokens) // 8) + 1):
        for start in range(len(tokens) - width * 8 + 1):
            pattern = tokens[start:start + width]
            end = start + width
            while end + width <= len(tokens) and tokens[end:end + width] == pattern:
                end += width
            repeated = end - start
            if repeated >= 24 and repeated >= len(tokens) * 0.6 and repeated >= width * 8:
                return "repetition_loop"
    return None


def retry_spans(data):
    """Cover every sample with bounded short windows, preferring quiet cuts."""
    import numpy as np
    spans, start = [], 0
    while len(data) - start > 12 * 16000:
        low, high = start + 6 * 16000, start + 10 * 16000
        frame = 320
        values = data[low:high]
        count = len(values) // frame
        energy = np.mean(values[:count * frame].reshape(count, frame) ** 2, axis=1)
        quietest = int(np.argmin(energy))
        end = low + quietest * frame + frame // 2 if float(energy[quietest]) < 0.002 ** 2 else high
        spans.append((start, end)); start = end
    if start < len(data):
        spans.append((start, len(data)))
    return spans


class RecognitionQualityError(RuntimeError):
    def __init__(self, attempts):
        super().__init__("识别结果出现异常重复或长度溢出，自动重试仍未通过。未采用异常文字，录音和原稿保留，请重试或回听这一片段。")
        self.quality = {"status": "failed", "attempts": attempts}


def recognize_guarded(model, data, language, hints, refining, clear_cache):
    """Try unchanged decoding first; repair only suspect output, never word-delete.

    Retry 1 removes potentially over-biasing terminology/context. Retry 2 uses
    short audio windows and a mild repetition penalty. All passes reuse the
    same model and bounded audio; raw attempts are returned for local evidence.
    """
    attempts, parts = [], []
    recovered = False
    budget = 768 if refining else 512

    def decode(start, end, strategy, prompt, limit, penalty=None):
        options = {"repetition_penalty": penalty} if penalty else {}
        try:
            result = model.generate(data[start:end], language=language or None,
                max_tokens=limit, chunk_duration=30.0 if refining else 20.0,
                batch_size=1, verbose=False, **prompt, **options)
            text = result.text.strip()
            tokens = getattr(result, "generation_tokens", None)
            problem = quality_problem(text, tokens, limit)
            attempt = {"start": start / 16000, "end": end / 16000,
                       "strategy": strategy, "text": text, "tokens": tokens, "problem": problem}
            attempts.append(attempt)
            del result
            return {"start": start / 16000, "end": end / 16000, "text": text}, problem
        finally:
            clear_cache()

    for start, end in ([(0, len(data))] if refining else recognition_spans(data)):
        part, problem = decode(start, end, "original", hints, budget)
        if not problem:
            parts.append(part); continue
        recovered = True
        part, problem = decode(start, end, "without_hints", {}, budget)
        if not problem:
            parts.append(part); continue
        for first, last in retry_spans(data[start:end]):
            part, problem = decode(start + first, start + last, "short_retry", {}, 384, 1.1)
            if problem:
                raise RecognitionQualityError(attempts)
            parts.append(part)
    quality = {"status": "recovered", "attempts": attempts} if recovered else None
    return parts, quality


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--test-memory", action="store_true")
    args = parser.parse_args()
    model_path = Path(args.model).resolve()
    if not (model_path / "config.json").exists():
        emit("error", message="本地模型尚未安装，请运行 setup.command。", fatal=True)
        return 2
    footprint()  # Check before loading weights.
    threading.Thread(target=monitor, args=(memory_limit(),), daemon=True).start()
    emit("status", message="正在载入本地中英文模型…")
    try:
        with contextlib.redirect_stdout(sys.stderr):
            import mlx.core as mx
            import numpy as np
            from mlx_audio.stt import load
            mx.set_cache_limit(64_000_000)
            mx.set_memory_limit(6_000_000_000)  # MLX guideline, not OS hard cap.
            model = load(str(model_path))
            mx.eval(model.parameters())
            if args.test_memory:
                emit("status", message="正在测试模型内存…")
                # Exercise a full second-pass input window without using any
                # meeting data or requiring audio permissions.
                time_axis = np.arange(30 * 16_000, dtype=np.float32) / 16_000
                sample = (0.05 * np.sin(2 * np.pi * 220 * time_axis)).astype(np.float32)
                model.generate(sample, max_tokens=96, chunk_duration=30.0, batch_size=1, verbose=False)
                mx.synchronize()
                emit("memory_test", peak=max(peak, footprint()))
                mx.clear_cache()
        emit("ready", bytes=footprint())
    except Exception as exc:
        emit("error", message=f"模型载入失败：{exc}", fatal=True)
        return 1

    for line in sys.stdin:
        job = {}
        try:
            job = json.loads(line)
            if not isinstance(job, dict):
                raise ValueError("Expected a JSON object")
            if job.get("command") == "shutdown":
                break
            hints = parse_recognition_hints(job)
            mode = job.get("mode", "live")
            if mode not in ("live", "refinement"):
                raise ValueError("Unknown transcription mode")
            refining = mode == "refinement"
            data = read_refinement_audio(job["path"], job.get("start_frame"), job.get("frame_count")) if refining else read_audio(job["path"])
            started = time.monotonic()
            # Silence gate only affects recognition, never the archived recording.
            voiced = len(data) > 0 and float(np.max(np.abs(data))) >= 0.002
            text, language = "", ""
            parts = []
            quality = None
            if voiced:
                with contextlib.redirect_stdout(sys.stderr):
                    parts, quality = recognize_guarded(model, data, job.get("language"), hints, refining, mx.clear_cache)
                    text = " ".join(part["text"] for part in parts if part["text"])
                    # mlx-audio's current Qwen metadata can report ["English"]
                    # even for correct Mandarin. Do not mislabel auto-detected text.
                    language = job.get("language") or ""
            emit("result", id=job["id"], text=text, language=language,
                 seconds=round(time.monotonic() - started, 3), bytes=footprint(), peak=peak,
                 parts=parts, quality=quality)
        except Exception as exc:
            emit("error", id=job.get("id") if isinstance(job, dict) else None,
                 message=str(exc), fatal=False, quality=getattr(exc, "quality", None))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
