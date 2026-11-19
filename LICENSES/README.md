# License text provenance

- The root `LICENSE` is the standard Apache License 2.0 text, including its unmodified example appendix. Actual project attribution is in `NOTICE`; the appendix's bracketed example is part of the license text, not an unfinished project attribution.
- `python/LICENSE.txt` was copied verbatim from the tested CPython 3.13.15 runtime.
- `dependencies/` preserves the license/notice files present in the tested Python distribution metadata, with their relative directory structure.
- `upstream/` contains additional license snapshots for Qwen3-ASR, SentencePiece and Tokenizers. See [upstream-provenance.json](upstream-provenance.json) for their URLs and Git blob identifiers.
- [dependency-inventory.json](dependency-inventory.json) lists package names, versions, declared license metadata and available copied notices. Version labels describe the tested runtime, which is not included in this source tree.

Original upstream texts are not translated or relicensed. Keep their attribution and component-specific conditions. Inspect native libraries and exact artifacts again before a public binary release; see [third-party notices](../THIRD_PARTY_NOTICES.md).
