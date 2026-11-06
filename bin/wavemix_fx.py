"""Manifest-driven microphone effect chain for Wavemix."""
from __future__ import annotations

import json
import math
import os
import re
import tempfile
import time
from pathlib import Path

WAVEMIX_VERSION = "1.1.0"
MANIFEST_SCHEMA_VERSION = 1
STATE_VERSION = 2

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

def bundled_dir() -> Path:
  """Where the installer puts the bundled plugin manifests."""
  base = os.environ.get("XDG_DATA_HOME")
  root = Path(base) if base else Path.home() / ".local" / "share"
  return root / "wavemix" / "plugins"


def user_dir() -> Path:
  """Where users drop their own plugin manifests."""
  base = os.environ.get("XDG_CONFIG_HOME")
  root = Path(base) if base else Path.home() / ".config"
  return root / "wavemix" / "plugins"


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


# ----------------------------------------------------------------------- state

def _micfx(state: dict) -> dict:
  micfx = state.get("micFx")
  if not isinstance(micfx, dict):
    micfx = {}
    state["micFx"] = micfx
  return micfx


def _read_chain(state: dict) -> list | None:
  if not isinstance(state, dict):
    return None
  micfx = state.get("micFx")
  if not isinstance(micfx, dict):
    return None
  chain = micfx.get("chain")
  return chain if isinstance(chain, list) else None


def _writable_chain(state: dict) -> list:
  chain = _micfx(state).get("chain")
  if not isinstance(chain, list):
    chain = []
    _micfx(state)["chain"] = chain
  return chain


def _new_instance(plugin_id: str, instance_id: str, manifest: dict) -> dict:
  return {
    "id": instance_id,
    "plugin": manifest.get("id") or plugin_id,
    "pluginVersion": manifest.get("version", ""),
    "enabled": True,
    "controls": manifest_defaults(manifest),
  }


def default_chain(manifests: dict[str, dict]) -> list[dict]:
  """One enabled instance for each usable manifest marked as a default."""
  chain = []
  for plugin_id in sorted(manifests):
    manifest = manifests[plugin_id]
    if not isinstance(manifest, dict):
      continue
    if not manifest.get("default"):
      continue
    if not manifest.get("available") or manifest.get("error"):
      continue
    chain.append(_new_instance(plugin_id, f"{plugin_id}-1", manifest))
  return chain


def _migrate_outputs(state: dict) -> None:
  devices = state.get("devices")
  if not isinstance(devices, dict):
    devices = {}
    state["devices"] = devices

  outputs = devices.get("outputs")
  if not isinstance(outputs, list):
    outputs = []
  outputs = [name for name in outputs if isinstance(name, str) and name]
  if not outputs:
    primary = devices.get("output")
    if not isinstance(primary, str) or not primary:
      primary = "@DEFAULT_SINK@"
    outputs = [primary]

  devices["outputs"] = outputs
  primary = devices.get("output")
  if not isinstance(primary, str) or primary not in outputs:
    devices["output"] = outputs[0]


def _state_version(value) -> int:
  """Coerce a state version, rejecting ambiguous or non-numeric values."""
  if isinstance(value, bool):
    raise FxError(f"invalid state version {value!r}")
  if isinstance(value, int):
    return value
  if isinstance(value, (float, str)):
    try:
      number = float(value)
    except (TypeError, ValueError):
      raise FxError(f"invalid state version {value!r}") from None
    if not math.isfinite(number) or not number.is_integer():
      raise FxError(f"invalid state version {value!r}")
    return int(number)
  raise FxError(f"invalid state version {value!r}")


def migrate_state(state: dict, manifests: dict[str, dict], version: str) -> dict:
  """Bring a loaded state up to STATE_VERSION without losing unknown fields."""
  if not isinstance(state, dict):
    state = {}

  raw_version = _state_version(state.get("version", 1))
  if raw_version > STATE_VERSION:
    raise FxError(
      f"state version {raw_version} is newer than supported version "
      f"{STATE_VERSION}; update Wavemix")

  micfx = _micfx(state)
  if raw_version < STATE_VERSION:
    controls = micfx.get("controls")
    if isinstance(controls, dict) and controls:
      rnnoise = manifests.get("rnnoise")
      if isinstance(rnnoise, dict):
        valid_keys = {
          control.get("key") for control in rnnoise.get("controls", [])
          if isinstance(control, dict)
        }
        migrated = {key: value for key, value in controls.items()
                    if key in valid_keys}
        for key, value in manifest_defaults(rnnoise).items():
          migrated.setdefault(key, value)
        plugin_version = rnnoise.get("version", "")
        micfx.pop("controls", None)
      else:
        # Manifest metadata is unavailable: keep every old value (and the
        # legacy controls map) so a later save cannot lose them.
        migrated = dict(controls)
        plugin_version = ""
      micfx["chain"] = [{
        "id": "rnnoise-1",
        "plugin": "rnnoise",
        "pluginVersion": plugin_version,
        "enabled": True,
        "controls": migrated,
      }]
    else:
      micfx["chain"] = default_chain(manifests)
  elif not isinstance(micfx.get("chain"), list):
    micfx["chain"] = default_chain(manifests)

  micfx.setdefault("enabled", False)
  state["version"] = STATE_VERSION
  _migrate_outputs(state)
  return state


def find_instance(state: dict, instance_id: str) -> dict | None:
  chain = _read_chain(state)
  if chain is None:
    return None
  for instance in chain:
    if isinstance(instance, dict) and instance.get("id") == instance_id:
      return instance
  return None


def add_instance(state: dict, manifests: dict[str, dict], plugin_id: str,
                 index: int | None = None) -> dict:
  """Add one instance, returning it, or raise FxError for an unusable plugin."""
  manifest = manifests.get(plugin_id)
  if not isinstance(manifest, dict):
    raise FxError(f"unknown plugin '{plugin_id}'")
  if not manifest.get("available") or manifest.get("error"):
    reason = manifest.get("error") or manifest.get("requires") \
        or "plugin is unavailable"
    raise FxError(f"cannot add plugin '{plugin_id}': {reason}")

  chain = _writable_chain(state)
  if not manifest.get("allowMultiple", True) \
      and any(isinstance(instance, dict)
              and instance.get("plugin") == plugin_id for instance in chain):
    raise FxError(f"plugin '{plugin_id}' does not allow multiple instances")

  used: set[int] = set()
  prefix = f"{plugin_id}-"
  for instance in chain:
    ident = instance.get("id") if isinstance(instance, dict) else None
    if not isinstance(ident, str) or not ident.startswith(prefix):
      continue
    suffix = ident[len(prefix):]
    if suffix.isdigit() and int(suffix) > 0:
      used.add(int(suffix))

  number = 1
  while number in used:
    number += 1
  instance = _new_instance(plugin_id, f"{plugin_id}-{number}", manifest)

  if index is None:
    chain.append(instance)
  else:
    try:
      position = int(index)
    except (TypeError, ValueError):
      position = len(chain)
    chain.insert(max(0, min(position, len(chain))), instance)
  return instance


def remove_instance(state: dict, instance_id: str) -> bool:
  chain = _read_chain(state)
  if chain is None:
    return False
  for position, instance in enumerate(chain):
    if isinstance(instance, dict) and instance.get("id") == instance_id:
      del chain[position]
      return True
  return False


def move_instance(state: dict, instance_id: str, direction: str) -> bool:
  chain = _read_chain(state)
  if chain is None:
    return False
  for position, instance in enumerate(chain):
    if not isinstance(instance, dict) or instance.get("id") != instance_id:
      continue
    if direction == "up" and position > 0:
      chain[position - 1], chain[position] = chain[position], chain[position - 1]
      return True
    if direction == "down" and position < len(chain) - 1:
      chain[position + 1], chain[position] = chain[position], chain[position + 1]
      return True
    return False
  return False


def toggle_instance(state: dict, instance_id: str) -> bool:
  instance = find_instance(state, instance_id)
  if instance is None:
    return False
  instance["enabled"] = not bool(instance.get("enabled", True))
  return True


def _decimal_places(number: float) -> int:
  text = f"{float(number):.12f}".rstrip("0").rstrip(".")
  return len(text.partition(".")[2])


def _quantize_step(number: float, minimum: float, maximum: float,
                   step: float) -> float:
  if step <= 0:
    return number
  snapped = minimum + round((number - minimum) / step) * step
  snapped = max(minimum, min(maximum, snapped))
  return round(snapped, max(_decimal_places(minimum), _decimal_places(step)))


def _clamp_display(spec: dict, value) -> float | int:
  try:
    number = float(value)
  except (TypeError, ValueError):
    number = float(spec.get("default", 0))
  minimum = float(spec.get("min", number))
  maximum = float(spec.get("max", number))
  number = max(minimum, min(maximum, number))
  if spec.get("integer"):
    return int(round(number))
  return _quantize_step(number, minimum, maximum,
                        float(spec.get("step", 0) or 0))


def set_instance_control(state: dict, manifests: dict[str, dict],
                         instance_id: str, key: str, value) -> dict | None:
  instance = find_instance(state, instance_id)
  if instance is None:
    return None
  manifest = manifests.get(instance.get("plugin"))
  if not isinstance(manifest, dict):
    return None
  spec = next((control for control in manifest.get("controls", [])
               if isinstance(control, dict) and control.get("key") == key), None)
  if spec is None:
    return None

  display = _clamp_display(spec, value)
  controls = instance.get("controls")
  if not isinstance(controls, dict):
    controls = {}
    instance["controls"] = controls
  controls[key] = display
  return {"instance": instance_id, "control": key, "value": display}


def enabled_instances(state: dict, manifests: dict[str, dict]) -> list[dict]:
  """Enabled, available instances in processing order with their fx node."""
  micfx = state.get("micFx") if isinstance(state, dict) else None
  if not isinstance(micfx, dict) or not micfx.get("enabled"):
    return []
  chain = micfx.get("chain")
  if not isinstance(chain, list):
    return []

  entries = []
  for instance in chain:
    if not isinstance(instance, dict):
      continue
    if not instance.get("enabled", True):
      continue
    manifest = manifests.get(instance.get("plugin"))
    if not isinstance(manifest, dict):
      continue
    if not manifest.get("available") or manifest.get("error"):
      continue
    entries.append({
      "instance": instance,
      "manifest": manifest,
      "node": f"fx{len(entries)}",
    })
  return entries


def node_for_instance(state: dict, manifests: dict[str, dict],
                      instance_id: str) -> str | None:
  for entry in enabled_instances(state, manifests):
    if entry["instance"].get("id") == instance_id:
      return entry["node"]
  return None


# ------------------------------------------------------------------- compiler

GENERATED_MARKER = (
  "# Generated by Wavemix. Do not edit by hand; use `wavemix fx`.")
CONFIG_NAME = "90-wavemix-micfx.conf"


def config_path() -> Path:
  """The generated PipeWire filter-chain fragment, honoring XDG_CONFIG_HOME."""
  base = os.environ.get("XDG_CONFIG_HOME")
  root = Path(base) if base else Path.home() / ".config"
  return root / "pipewire" / "pipewire.conf.d" / CONFIG_NAME


def _spa_quote(text: str) -> str:
  """Quote one SPA config string, escaping everything that could break it."""
  escaped = str(text).replace("\\", "\\\\").replace('"', '\\"')
  escaped = escaped.replace("\r", "\\r").replace("\n", "\\n")
  escaped = escaped.replace("\t", "\\t")
  return f'"{escaped}"'


def _spa_value(value) -> str:
  """Render a scalar, list, or map in SPA config syntax."""
  if isinstance(value, bool):
    return "true" if value else "false"
  if isinstance(value, str):
    return _spa_quote(value)
  if isinstance(value, int):
    return str(value)
  if isinstance(value, float):
    return f"{value:.6f}"
  if isinstance(value, (list, tuple)):
    if not value:
      return "[ ]"
    return "[ " + " ".join(_spa_value(item) for item in value) + " ]"
  if isinstance(value, dict):
    if not value:
      return "{ }"
    pairs = " ".join(f"{_spa_quote(str(key))} = {_spa_value(item)}"
                     for key, item in value.items())
    return "{ " + pairs + " }"
  raise FxError(f"cannot render config value {value!r}")


def _control_raw(value, spec: dict) -> float | int:
  """Convert one display-unit control value to its raw plugin value."""
  try:
    number = float(value)
  except (TypeError, ValueError):
    number = float(spec.get("default", 0))
  if not math.isfinite(number):
    number = float(spec.get("default", 0))
  try:
    scale = float(spec.get("scale", 1))
  except (TypeError, ValueError):
    scale = 1.0
  if scale <= 0 or not math.isfinite(scale):
    scale = 1.0
  raw = number / scale
  if spec.get("raw_float") or not raw.is_integer():
    return float(raw)
  return int(round(raw))


def _control_block(manifest: dict, instance: dict) -> str | None:
  stored = instance.get("controls")
  if not isinstance(stored, dict):
    stored = {}
  pairs = []
  for spec in manifest.get("controls", []):
    if not isinstance(spec, dict) or not spec.get("param"):
      continue
    key = spec.get("key")
    value = stored.get(key, spec.get("default"))
    pairs.append(f"{_spa_quote(spec['param'])} = "
                 f"{_spa_value(_control_raw(value, spec))}")
  if not pairs:
    return None
  return "{ " + " ".join(pairs) + " }"


def _node_lines(entry: dict) -> list[str]:
  manifest = entry["manifest"]
  pieces = [
    f"type = {manifest.get('type', 'builtin')}",
    f"name = {entry['node']}",
  ]
  if manifest.get("plugin"):
    pieces.append(f"plugin = {_spa_quote(manifest['plugin'])}")
  if manifest.get("label"):
    pieces.append(f"label = {_spa_quote(manifest['label'])}")
  config = manifest.get("config")
  if isinstance(config, dict) and config:
    pieces.append(f"config = {_spa_value(config)}")
  controls = _control_block(manifest, entry["instance"])
  if controls:
    pieces.append(f"control = {controls}")

  lines = [f"{{ {pieces[0]}"]
  lines.extend(f"  {piece}" for piece in pieces[1:])
  lines[-1] += " }"
  return lines


def _port(entry: dict, port: str) -> str:
  return f"{entry['node']}:{entry['manifest'].get(port, '')}"


def render_config(state: dict, manifests: dict[str, dict],
                  version: str) -> str:
  """Compile the enabled chain into one PipeWire filter-chain fragment."""
  entries = enabled_instances(state, manifests)
  names = " -> ".join(
    str(entry["manifest"].get("id", "?")) for entry in entries) or "empty"
  core = str(version).replace("\n", " ").replace("\r", " ")
  lines = [GENERATED_MARKER, f"# Core {core}; chain: {names}"]

  if not entries:
    lines.append("# No effects enabled; the microphone uses the raw feed.")
    return "\n".join(lines) + "\n"

  lines.extend([
    "context.modules = [",
    "  { name = libpipewire-module-filter-chain",
    "    args = {",
    '      node.description = "Wavemix FX"',
    '      media.name = "Wavemix FX"',
    "      filter.graph = {",
    "        nodes = [",
  ])
  for entry in entries:
    lines.extend(f"          {line}" for line in _node_lines(entry))
  lines.append("        ]")

  if len(entries) > 1:
    lines.append("        links = [")
    for previous, following in zip(entries, entries[1:]):
      lines.append(
        f"          {{ output = {_spa_quote(_port(previous, 'output'))} "
        f"input = {_spa_quote(_port(following, 'input'))} }}")
    lines.append("        ]")

  lines.extend([
    f"        inputs = {_spa_value([_port(entries[0], 'input')])}",
    f"        outputs = {_spa_value([_port(entries[-1], 'output')])}",
    "      }",
    "      audio.rate = 48000",
    "      audio.position = [ MONO ]",
    "      capture.props = {",
    '        node.name = "wavemix_micfx.capture"',
    "        node.autoconnect = false",
    "        node.passive = true",
    "      }",
    "      playback.props = {",
    '        node.name = "wavemix_micfx"',
    "        node.autoconnect = false",
    "        node.passive = true",
    "      }",
    "    }",
    "  }",
    "]",
  ])
  return "\n".join(lines) + "\n"


def _backup_path(path: Path) -> Path:
  stamp = time.strftime("%Y%m%dT%H%M%S")
  return path.with_name(f"{path.name}.bak-{stamp}")


def write_config(path: Path, content: str) -> bool:
  """Atomically write content, backing up a handwritten file just once."""
  path = Path(path)
  try:
    existing = path.read_text(encoding="utf-8")
  except (OSError, UnicodeError):
    existing = None
  if existing == content:
    return False

  try:
    path.parent.mkdir(parents=True, exist_ok=True)
  except OSError as exc:
    raise FxError(f"cannot create {path.parent}: {exc}") from exc

  if existing is not None and GENERATED_MARKER not in existing \
      and not any(path.parent.glob(path.name + ".bak-*")):
    backup = _backup_path(path)
    try:
      backup.write_text(existing, encoding="utf-8")
    except OSError as exc:
      raise FxError(f"cannot back up {path}: {exc}") from exc

  temporary = None
  try:
    descriptor, temporary = tempfile.mkstemp(
      dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
      handle.write(content)
    os.replace(temporary, path)
  except OSError as exc:
    if temporary:
      try:
        os.unlink(temporary)
      except OSError:
        pass
    raise FxError(f"cannot write {path}: {exc}") from exc
  return True


def render_to_disk(state: dict, manifests: dict[str, dict], version: str,
                   path: Path | None = None) -> bool:
  """Render the chain and write it to the generated config path."""
  target = Path(path) if path is not None else config_path()
  return write_config(target, render_config(state, manifests, version))
