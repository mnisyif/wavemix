"""Manifest-driven microphone effect chain for Wavemix."""
from __future__ import annotations

import json
import math
import os
import re
from pathlib import Path

WAVEMIX_VERSION = "1.1.0"
MANIFEST_SCHEMA_VERSION = 1

_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
_CONTROL_KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
_MANIFEST_TYPES = ("ladspa", "lv2", "builtin")
_PLUGIN_LIST_FIELDS = (
  "id", "name", "description", "version", "schemaVersion", "minWavemix",
  "source", "available", "gpu", "requires", "error",
)


class FxError(Exception):
  """A user-facing effect-chain error."""

  def __init__(self, message: str):
    super().__init__(message)
    self.message = message


def parse_version(text: str) -> tuple[int, int, int] | None:
  value = str(text or "").strip()
  if not _VERSION_RE.match(value):
    return None
  return tuple(int(part) for part in value.split("."))


def version_at_least(current: str, minimum: str) -> bool:
  cur = parse_version(current)
  want = parse_version(minimum)
  if cur is None or want is None:
    return False
  return cur >= want


# ------------------------------------------------------------------- manifests

def _synthetic_id(path: Path) -> str:
  stem = re.sub(r"[^a-z0-9_-]+", "_", Path(path).stem.lower()).strip("_-")
  return stem or "manifest"


def _expand_plugin(value: str) -> str:
  return os.path.expandvars(os.path.expanduser(value))


def _text(data: dict, key: str, field: str | None = None) -> str:
  value = data.get(key)
  if not isinstance(value, str) or not value.strip():
    raise FxError(f"{field or key} must be a non-empty string")
  return value


def _optional_text(data: dict, key: str, default: str) -> str:
  value = data.get(key, default)
  if not isinstance(value, str):
    raise FxError(f"{key} must be a string")
  return value


def _boolean(data: dict, key: str, default: bool) -> bool:
  value = data.get(key, default)
  if not isinstance(value, bool):
    raise FxError(f"{key} must be true or false")
  return value


def _number(value, field: str):
  if isinstance(value, bool) or not isinstance(value, (int, float)):
    raise FxError(f"{field} must be a number")
  if not math.isfinite(float(value)):
    raise FxError(f"{field} must be finite")
  return value


def _normalize_control(raw, index: int, seen: set[str]) -> dict:
  if not isinstance(raw, dict):
    raise FxError(f"controls[{index}] must be an object")
  key = _text(raw, "key").strip()
  if not _CONTROL_KEY_RE.match(key):
    raise FxError(f"invalid control key '{key}'")
  if key in seen:
    raise FxError(f"duplicate control key '{key}'")
  seen.add(key)

  param = _text(raw, "param", f"control '{key}' param")
  label = _optional_text(raw, "label", param)
  unit = _optional_text(raw, "unit", "")
  minimum = _number(raw.get("min"), f"control '{key}' min")
  maximum = _number(raw.get("max"), f"control '{key}' max")
  step = _number(raw.get("step", 1), f"control '{key}' step")
  default = _number(raw.get("default", minimum), f"control '{key}' default")
  scale = _number(raw.get("scale", 1), f"control '{key}' scale")
  integer = _boolean(raw, "integer", False)
  raw_float = _boolean(raw, "raw_float", False)

  if minimum > maximum:
    raise FxError(
      f"control '{key}' range is invalid: min {minimum} > max {maximum}")
  if step <= 0:
    raise FxError(f"control '{key}' range is invalid: step must be positive")
  if scale <= 0:
    raise FxError(f"control '{key}' range is invalid: scale must be positive")

  return {
    "key": key,
    "param": param,
    "label": label,
    "min": minimum,
    "max": maximum,
    "step": step,
    "unit": unit,
    "default": default,
    "integer": integer,
    "raw_float": raw_float,
    "scale": scale,
  }


def _validated_manifest(data: dict, source: str, path: Path,
                        version: str) -> dict:
  if not isinstance(data, dict):
    raise FxError("manifest must be a JSON object")

  schema = data.get("schemaVersion")
  if isinstance(schema, bool) or not isinstance(schema, int):
    raise FxError("schemaVersion must be an integer")
  if schema != MANIFEST_SCHEMA_VERSION:
    raise FxError(f"unsupported manifest schemaVersion {schema}; "
                  f"expected {MANIFEST_SCHEMA_VERSION}")

  ident = _text(data, "id").strip()
  if not _ID_RE.match(ident):
    raise FxError(f"invalid id '{ident}': use lowercase letters, digits, "
                  "'_' or '-'")

  plugin_version = _text(data, "version").strip()
  if parse_version(plugin_version) is None:
    raise FxError(f"invalid version '{plugin_version}': "
                  "expected MAJOR.MINOR.PATCH")

  minimum = _optional_text(data, "minWavemix", WAVEMIX_VERSION).strip()
  if parse_version(minimum) is None:
    raise FxError(f"invalid minWavemix '{minimum}': "
                  "expected MAJOR.MINOR.PATCH")

  name = _text(data, "name").strip()
  description = _optional_text(data, "description", "")
  kind = _text(data, "type").strip()
  if kind not in _MANIFEST_TYPES:
    raise FxError(f"unknown type '{kind}': expected one of "
                  f"{', '.join(_MANIFEST_TYPES)}")

  plugin = _optional_text(data, "plugin", "").strip()
  label = _optional_text(data, "label", "").strip()
  if kind == "ladspa":
    if not plugin:
      raise FxError("ladspa manifest requires a plugin path")
    plugin = _expand_plugin(plugin)
  elif kind == "lv2":
    if not plugin:
      raise FxError("lv2 manifest requires a plugin URI")
  else:
    plugin = ""
  if kind in ("ladspa", "builtin") and not label:
    raise FxError(f"{kind} manifest requires a label")

  config = data.get("config", {})
  if not isinstance(config, dict):
    raise FxError("config must be an object")

  input_port = _text(data, "input").strip()
  output_port = _text(data, "output").strip()
  if not input_port or not output_port:
    raise FxError("input and output must be non-empty strings")

  controls_raw = data.get("controls")
  if not isinstance(controls_raw, list):
    raise FxError("controls must be a list")
  controls = []
  seen: set[str] = set()
  for index, raw in enumerate(controls_raw):
    controls.append(_normalize_control(raw, index, seen))

  manifest = dict(data)
  manifest.update({
    "schemaVersion": schema,
    "id": ident,
    "version": plugin_version,
    "minWavemix": minimum,
    "name": name,
    "description": description,
    "type": kind,
    "plugin": plugin,
    "label": label,
    "input": input_port,
    "output": output_port,
    "config": config,
    "gpu": _boolean(data, "gpu", False),
    "requires": _optional_text(data, "requires", ""),
    "default": _boolean(data, "default", False),
    "allowMultiple": _boolean(data, "allowMultiple", True),
    "controls": controls,
    "source": source,
    "path": str(path),
    "available": True,
    "error": None,
  })
  return manifest


def _invalid_manifest(data, source: str, path: Path) -> dict:
  if not isinstance(data, dict):
    data = {}
  ident = data.get("id")
  if isinstance(ident, str) and _ID_RE.match(ident.strip()):
    ident = ident.strip()
  else:
    ident = _synthetic_id(path)

  def text(key: str, default: str = "") -> str:
    value = data.get(key, default)
    return value if isinstance(value, str) else default

  schema = data.get("schemaVersion", 0)
  if isinstance(schema, bool) or not isinstance(schema, int):
    schema = 0
  config = data.get("config")
  gpu = data.get("gpu")
  default = data.get("default")
  allow_multiple = data.get("allowMultiple")
  return {
    "schemaVersion": schema,
    "id": ident,
    "version": text("version"),
    "minWavemix": text("minWavemix", WAVEMIX_VERSION),
    "name": text("name") or ident,
    "description": text("description"),
    "type": text("type"),
    "plugin": _expand_plugin(text("plugin")),
    "label": text("label"),
    "input": text("input"),
    "output": text("output"),
    "config": config if isinstance(config, dict) else {},
    "gpu": gpu if isinstance(gpu, bool) else False,
    "requires": text("requires"),
    "default": default if isinstance(default, bool) else False,
    "allowMultiple": allow_multiple if isinstance(allow_multiple, bool) else True,
    "controls": [],
    "source": source,
    "path": str(path),
    "available": False,
    "error": None,
  }


def _normalize_manifest(data, source: str, path: Path, version: str,
                        lv2_uris: set[str] | None) -> tuple[dict, bool]:
  try:
    manifest = _validated_manifest(data, source, path, version)
  except FxError as exc:
    entry = _invalid_manifest(data, source, path)
    entry["error"] = str(exc)
    return entry, False

  error = None
  if not version_at_least(version, manifest["minWavemix"]):
    error = f"manifest requires wavemix {manifest['minWavemix']} or newer"
  elif manifest["type"] == "ladspa":
    try:
      present = Path(manifest["plugin"]).is_file()
    except (OSError, ValueError):
      present = False
    if not present:
      error = f"LADSPA plugin not found: {manifest['plugin']}"
  elif (manifest["type"] == "lv2" and lv2_uris is not None
        and manifest["plugin"] not in lv2_uris):
    error = f"LV2 plugin not found: {manifest['plugin']}"

  manifest["available"] = error is None
  manifest["error"] = error
  return manifest, True


def normalize_manifest(data: dict, *, source: str, path: Path, version: str,
                       lv2_uris: set[str] | None = None) -> dict:
  """Normalize one manifest dict, marking it available or explaining why not."""
  manifest, _valid = _normalize_manifest(data, source, path, version, lv2_uris)
  return manifest


def _manifest_paths(directory: Path) -> list[Path]:
  try:
    return sorted(
      (path for path in Path(directory).glob("*.json") if path.is_file()),
      key=lambda path: path.name)
  except OSError:
    return []


def _load_manifest(path: Path, source: str, version: str,
                   lv2_uris: set[str] | None) -> tuple[dict, bool]:
  try:
    data = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    entry = _invalid_manifest({}, source, path)
    entry["error"] = f"cannot read manifest: {exc}"
    return entry, False
  if not isinstance(data, dict):
    entry = _invalid_manifest({}, source, path)
    entry["error"] = "manifest must be a JSON object"
    return entry, False
  return _normalize_manifest(data, source, path, version, lv2_uris)


def _unique_key(base: str, manifests: dict[str, dict]) -> str:
  if base not in manifests:
    return base
  number = 2
  while f"{base}_{number}" in manifests:
    number += 1
  return f"{base}_{number}"


def discover_manifests(bundled_dir: Path, user_dir: Path, version: str,
                       lv2_uris: set[str] | None = None) -> dict[str, dict]:
  """Load bundled then user manifests, letting valid user entries win by id."""
  manifests: dict[str, dict] = {}
  for source, directory in (("bundled", bundled_dir), ("user", user_dir)):
    for path in _manifest_paths(directory):
      entry, valid = _load_manifest(path, source, version, lv2_uris)
      ident = entry["id"]
      if valid and ident not in manifests:
        manifests[ident] = entry
        continue
      if valid and source == "user" \
          and manifests[ident]["source"] == "bundled":
        manifests[ident] = entry
        continue
      if valid:
        duplicate = dict(entry)
        duplicate["available"] = False
        duplicate["error"] = f"duplicate manifest id '{ident}'"
        manifests[_unique_key(_synthetic_id(path), manifests)] = duplicate
        continue
      manifests[_unique_key(_synthetic_id(path), manifests)] = entry
  return manifests


def manifest_defaults(manifest: dict) -> dict[str, float | int]:
  """Control key -> display-unit default for one normalized manifest."""
  return {control["key"]: control["default"]
          for control in manifest.get("controls", [])}


def plugin_list(manifests: dict[str, dict]) -> list[dict]:
  """Stable rows for `wavemix fx plugins` and the popup."""
  rows = [{field: manifest.get(field) for field in _PLUGIN_LIST_FIELDS}
          for manifest in manifests.values()]
  return sorted(rows, key=lambda row: (row["id"], row["source"]))
