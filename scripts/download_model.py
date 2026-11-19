"""Explicit developer download, using the same pinned checks as the app installer."""
import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("manage_model", root / "engine/manage_model.py")
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)
manifest = json.loads((root / "engine/model-manifest.json").read_text())
print(manager.install(root / "models", manifest))
