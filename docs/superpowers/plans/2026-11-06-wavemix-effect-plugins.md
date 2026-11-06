# Wavemix Effect Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded RNNoise mic filter with a versioned, manifest-driven effect chain that supports add/remove/reorder/bypass, live controls, GPU denoisers, and duplicate the output mix across multiple selected hardware outputs.

**Architecture:** A new `bin/wavemix_fx.py` module owns manifests, state migration, chain compilation, config rendering, and live control mapping. `bin/wavemix` exposes `fx` commands and keeps `micfx` as a compatibility adapter. The chain compiles into one generated PipeWire filter-chain config; structural changes restart PipeWire, control changes use `pw-cli set-param` and never interrupt audio. Each channel output send creates one loopback per selected hardware output, sharing the channel fader. The bar popup becomes an Effects popup driven by `wavemix fx state --json`.

**Tech Stack:** Python 3.10+ standard library, PipeWire filter-chain (`libpipewire-module-filter-chain`), `pw-cli`/`pw-dump`/`systemctl`, Quickshell/QML (Omarchy plugin), `unittest`.

**Spec:** `docs/superpowers/specs/2026-11-06-wavemix-effect-plugins-design.md`

## Global Constraints

- Target release is `1.1.0`; `VERSION` and `WAVEMIX_VERSION` must match.
- State schema is version `2`; manifest schema version is `1`.
- Effect chains are mono (`audio.position = [ MONO ]`) and microphone-only.
- Only native `ladspa`, `lv2`, and `builtin` nodes are supported; no external daemons.
- Structural changes use `systemctl --user restart pipewire pipewire-pulse wireplumber`; control changes never restart audio.
- Never overwrite a newer state version; never install or download anything from a manifest.
- Bundled manifests install to `~/.local/share/wavemix/plugins`; user manifests live in `~/.config/wavemix/plugins`.
- Generated config path is `~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf`.
- The output mix is duplicated to every selected hardware output; one channel output fader controls all copies.
- At least one output must remain selected; `devices.output` is the first/primary entry of `devices.outputs`.
- Existing `micfx on|off|toggle|controls|set` commands remain functional.
- Run tests with `python3 -m unittest discover -s tests -v`.
- QML changes are verified manually; there is no QML test harness.
- Every commit message states the user-visible behavior and the verification performed.

## Review Focus

- An incompatible manifest (`schemaVersion`, `minWavemix`, bad control range) must appear as unavailable with a clear reason and must never break the rest of the chain. Pin this in Task 2.
- An old v1 state with `micFx.controls`, partial controls, or no controls must migrate without losing values and without inventing a broken chain. Pin this in Task 3.
- Disabled, missing, or bypassed effects must be skipped cleanly, and port/control names with spaces, `%`, `()`, or `:` must remain correctly quoted. Pin this in Task 4.
- Setting a live control while PipeWire or the chain node is absent must store the value, report `applied: false`, and apply it after the next restart. Pin this in Task 5.
- GPU manifests (Maxine/DeepFilterNet) must show an install hint and stay un-addable when their `.so` is missing, without hiding the rest of the plugin list. Pin this in Task 2.
- A vanished output, or removing the last selected output, must leave at least one hardware output and must not silently drop the mix. Pin this in Tasks 8 and 9.
- Mixed output mute states must produce the documented all-muted/toggle-all behavior. Pin this in Task 9.

---

### Task 1: Version foundation and module skeleton

**Files:**
- Create: `VERSION`
- Create: `CHANGELOG.md`
- Create: `bin/wavemix_fx.py`
- Modify: `bin/wavemix:1-35` (imports), `bin/wavemix:1146-1151` (`main`)
- Modify: `plugin/manifest.json:5`
- Modify: `tests/test_wavemix.py:1-14` (module import)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `wavemix_fx.WAVEMIX_VERSION: str`
  - `wavemix_fx.parse_version(text: str) -> tuple[int, int, int] | None`
  - `wavemix_fx.version_at_least(current: str, minimum: str) -> bool`
  - `wavemix --version`

- [ ] **Step 1: Write the failing version tests**

Add to `tests/test_wavemix.py`:

```python
import subprocess
import sys

sys.path.insert(0, str(ROOT / "bin"))
import wavemix_fx


class VersionTests(unittest.TestCase):
  def test_version_file_matches_module_constant(self):
    self.assertEqual((ROOT / "VERSION").read_text().strip(), wavemix_fx.WAVEMIX_VERSION)

  def test_parse_version_accepts_numeric_triples(self):
    self.assertEqual(wavemix_fx.parse_version("1.2.3"), (1, 2, 3))
    self.assertIsNone(wavemix_fx.parse_version("1.2"))
    self.assertIsNone(wavemix_fx.parse_version("v1.2.3"))

  def test_version_at_least(self):
    self.assertTrue(wavemix_fx.version_at_least("1.2.0", "1.1.9"))
    self.assertTrue(wavemix_fx.version_at_least("1.1.0", "1.1.0"))
    self.assertFalse(wavemix_fx.version_at_least("1.0.9", "1.1.0"))

  def test_cli_version_output(self):
    out = subprocess.run(
      [sys.executable, str(ROOT / "bin" / "wavemix"), "--version"],
      capture_output=True, text=True, check=True)
    self.assertEqual(out.stdout.strip(), f"wavemix {wavemix_fx.WAVEMIX_VERSION}")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL/import error because `wavemix_fx`, `VERSION`, and `--version` do not exist.

- [ ] **Step 3: Add the version module and CLI wiring**

`bin/wavemix_fx.py`:

```python
"""Manifest-driven microphone effect chain for Wavemix."""
from __future__ import annotations

import re

WAVEMIX_VERSION = "1.1.0"

_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")

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
```

`bin/wavemix` imports it after the standard imports:

```python
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wavemix_fx as fx
```

Add to `build_parser()` before the subparsers:

```python
parser = argparse.ArgumentParser(...)
parser.add_argument("--version", action="version", version=f"wavemix {fx.WAVEMIX_VERSION}")
```

Create `VERSION` containing `1.1.0` and `CHANGELOG.md` with:

```markdown
# Changelog

## [1.1.0] - 2026-11-06

- Add the manifest-driven microphone effect chain.
- Add live effect controls, chain ordering, bypass, and version tracking.
- Add bundled RNNoise, high-pass, noise-gate, DeepFilterNet, and Maxine manifests.
```

Bump `plugin/manifest.json` `"version"` to `"1.1.0"`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS, including the four new version tests.

- [ ] **Step 5: Commit**

```bash
git add VERSION CHANGELOG.md bin/wavemix bin/wavemix_fx.py plugin/manifest.json tests/test_wavemix.py
git commit -m "feat: add core and plugin version foundations" -m "Add VERSION, wavemix --version, manifest schema constants, semantic version comparison for minWavemix, and a changelog. Bump the Omarchy plugin manifest to 1.1.0 to match the release."
```

---

### Task 2: Manifest discovery and validation

**Files:**
- Modify: `bin/wavemix_fx.py`
- Create: `plugins/rnnoise.json`
- Create: `plugins/highpass.json`
- Create: `plugins/noisegate.json`
- Create: `plugins/deepfilternet.json`
- Create: `plugins/maxine-denoise.json`
- Modify: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: `WAVEMIX_VERSION`, `parse_version`, `version_at_least`.
- Produces:
  - `wavemix_fx.FxError(Exception)`
  - `wavemix_fx.MANIFEST_SCHEMA_VERSION: int`
  - `wavemix_fx.normalize_manifest(data: dict, *, source: str, path: Path, version: str, lv2_uris: set[str] | None = None) -> dict`
  - `wavemix_fx.discover_manifests(bundled_dir: Path, user_dir: Path, version: str, lv2_uris: set[str] | None = None) -> dict[str, dict]`
  - `wavemix_fx.manifest_defaults(manifest: dict) -> dict[str, float | int]`
  - `wavemix_fx.plugin_list(manifests: dict[str, dict]) -> list[dict]`

The normalized manifest adds `source`, `path`, `available`, `error`, expands `~`/`$HOME` in LADSPA `plugin` paths, and fills defaults for `description`, `config`, `gpu`, `requires`, `default`, `allowMultiple`, and control flags.

- [ ] **Step 1: Write the failing manifest tests**

Add `ManifestTests`:

```python
class ManifestTests(unittest.TestCase):
  def test_valid_manifest_normalizes_defaults(self):
    data = {
      "schemaVersion": 1, "id": "demo", "version": "1.0.0",
      "name": "Demo", "type": "builtin", "label": "bq_highpass",
      "input": "In", "output": "Out", "controls": [],
    }
    manifest = wavemix_fx.normalize_manifest(
      data, source="bundled", path=Path("/tmp/demo.json"),
      version="1.1.0")
    self.assertTrue(manifest["available"])
    self.assertIsNone(manifest["error"])
    self.assertEqual(manifest["allowMultiple"], True)
    self.assertEqual(manifest["source"], "bundled")

  def test_incompatible_min_wavemix_is_unavailable(self):
    data = {
      "schemaVersion": 1, "id": "future", "version": "1.0.0",
      "minWavemix": "9.0.0", "name": "Future", "type": "builtin",
      "label": "noisegate", "input": "In", "output": "Out", "controls": [],
    }
    manifest = wavemix_fx.normalize_manifest(
      data, source="user", path=Path("/tmp/future.json"),
      version="1.1.0")
    self.assertFalse(manifest["available"])
    self.assertIn("9.0.0", manifest["error"])

  def test_missing_ladspa_file_is_unavailable(self):
    data = {
      "schemaVersion": 1, "id": "missing", "version": "1.0.0",
      "name": "Missing", "type": "ladspa", "plugin": "/no/such/plugin.so",
      "label": "missing", "input": "In", "output": "Out",
      "requires": "Install the missing plugin", "controls": [],
    }
    manifest = wavemix_fx.normalize_manifest(
      data, source="user", path=Path("/tmp/missing.json"),
      version="1.1.0")
    self.assertFalse(manifest["available"])
    self.assertEqual(manifest["requires"], "Install the missing plugin")

  def test_user_manifest_overrides_bundled_by_id(self):
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
      # Write bundled/demo.json and user/demo.json with different versions.
      # discover_manifests(...) must return the user version and source="user".
```

Also add a test that every bundled manifest validates and `rnnoise` is `default: true`, and a test that a missing Maxine LADSPA file is unavailable while the manifest remains listed.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL with `AttributeError: module 'wavemix_fx' has no attribute 'normalize_manifest'`.

- [ ] **Step 3: Implement manifest discovery and add the bundled manifests**

Implementation rules:

- `FxError` carries a human-readable message.
- `normalize_manifest` validates required fields, id/control-key slugs (manifest ids allow hyphens, e.g. `maxine-denoise`), version/minWavemix, type, ranges (`min <= max`, `step > 0`, `scale > 0`), and non-empty input/output.
- LADSPA availability checks the expanded plugin path with `Path.is_file()`. Builtin is always available. LV2 is available if `lv2_uris is None` or the URI is in the set.
- Invalid manifests return a normalized entry with `available: false`, `error: "<reason>"`, and a synthetic id derived from the filename when `id` is unavailable.
- `discover_manifests` sorts files by name, collects bundled then user manifests, replaces bundled entries with valid user entries of the same id, and keeps invalid user entries as separate error rows.
- `manifest_defaults` returns control-key → display default.
- `plugin_list` returns stable entries: `id`, `name`, `description`, `version`, `schemaVersion`, `minWavemix`, `source`, `available`, `gpu`, `requires`, `error`.

Bundled manifests (exact values):

- `rnnoise.json`: LADSPA `/usr/lib/ladspa/librnnoise_ladspa.so`, label `noise_suppressor_mono`, `Input`/`Output`, `default: true`, controls `vadThreshold` (0–99, step 1, default 50, `%`, integer), `vadGrace` (0–1000, step 10, default 200, ` ms`, integer), `retroactiveGrace` (0–200, step 5, default 0, ` ms`, integer), `dryMix` (0–100, step 1, default 0, `%`, integer, `raw_float: true`, `scale: 100`).
- `highpass.json`: builtin `bq_highpass`, `In`/`Out`, controls `freq` (`Freq`, 20–500 Hz, step 5, default 80) and `q` (`Q`, 0.1–5, step 0.1, default 0.707, non-integer).
- `noisegate.json`: builtin `noisegate`, `In`/`Out`, controls `openThreshold` (`Open Threshold`, 0–1, step 0.01, default 0.04), `closeThreshold` (`Close Threshold`, 0–1, step 0.01, default 0.03), `attack` (`Attack (s)`, 0–1, step 0.001, default 0.005), `hold` (`Hold (s)`, 0–1, step 0.001, default 0.05), `release` (`Release (s)`, 0–1, step 0.001, default 0.01).
- `deepfilternet.json`: LADSPA `/usr/lib/ladspa/libdeep_filter_ladspa.so`, label `deep_filter_mono`, `Audio In`/`Audio Out`, `gpu: false`, `requires: "Install deepfilternet-ladspa"`, control `attenuationLimit` (`Attenuation Limit (dB)`, 0–100, step 1, default 100, ` dB`).
- `maxine-denoise.json`: LADSPA `~/.local/lib/ladspa/libmaxine_ladspa.so`, label `maxine_denoiser_mono`, `Input L`/`Output L`, `gpu: true`, `requires: "Install broadcast-maxine-ladspa and the NVIDIA Maxine runtime; add ~/.local/lib/ladspa to LADSPA_PATH if needed"`, control `intensity` (`Intensity`, 0–1, step 0.05, default 1.0, non-integer).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS for manifest tests and all bundled-manifest validation tests.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix_fx.py plugins tests/test_wavemix.py
git commit -m "feat: add versioned effect manifest discovery" -m "Validate bundled and user manifests, enforce schema/minWavemix compatibility, resolve LADSPA paths, and expose availability plus install hints. Add the RNNoise, high-pass, noise-gate, DeepFilterNet, and Maxine manifests with their real control ranges."
```

---

### Task 3: State model, default chain, and migration

**Files:**
- Modify: `bin/wavemix_fx.py`
- Modify: `bin/wavemix:50-70` (`DEFAULT_STATE`), `bin/wavemix:227-240` (`load_state`)
- Modify: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: `discover_manifests`, `manifest_defaults`, `FxError`.
- Produces:
  - `STATE_VERSION = 2`
  - `wavemix_fx.default_chain(manifests: dict[str, dict]) -> list[dict]`
  - `wavemix_fx.migrate_state(state: dict, manifests: dict[str, dict], version: str) -> dict`
  - `wavemix_fx.find_instance(state: dict, instance_id: str) -> dict | None`
  - `wavemix_fx.add_instance(state, manifests, plugin_id: str, index: int | None = None) -> dict`
  - `wavemix_fx.remove_instance(state, instance_id: str) -> bool`
  - `wavemix_fx.move_instance(state, instance_id: str, direction: str) -> bool`
  - `wavemix_fx.toggle_instance(state, instance_id: str) -> bool`
  - `wavemix_fx.set_instance_control(state, manifests, instance_id: str, key: str, value) -> dict | None`
  - `wavemix_fx.enabled_instances(state, manifests) -> list[dict]` (each has `instance`, `manifest`, `node`)
  - `wavemix_fx.node_for_instance(state, manifests, instance_id: str) -> str | None`

- [ ] **Step 1: Write the failing state tests**

Add `StateTests`:

```python
class StateTests(unittest.TestCase):
  def test_v1_controls_migrate_to_rnnoise_instance(self):
    state = {"version": 1, "micFx": {"enabled": True,
             "controls": {"vadThreshold": 35, "dryMix": 50}}}
    migrated = wavemix_fx.migrate_state(state, manifests, "1.1.0")
    self.assertEqual(migrated["version"], 2)
    self.assertEqual(migrated["micFx"]["chain"][0]["id"], "rnnoise-1")
    self.assertEqual(migrated["micFx"]["chain"][0]["pluginVersion"], manifests["rnnoise"]["version"])
    self.assertEqual(migrated["micFx"]["chain"][0]["controls"]["vadThreshold"], 35)
    self.assertEqual(migrated["micFx"]["chain"][0]["controls"]["dryMix"], 50)

  def test_v1_without_controls_uses_default_chain(self):
    state = {"version": 1, "micFx": {"enabled": False}}
    migrated = wavemix_fx.migrate_state(state, manifests, "1.1.0")
    self.assertEqual([i["plugin"] for i in migrated["micFx"]["chain"]], ["rnnoise"])

  def test_newer_state_version_is_rejected(self):
    with self.assertRaises(wavemix_fx.FxError):
      wavemix_fx.migrate_state({"version": 3}, manifests, "1.1.0")

  def test_missing_outputs_migrates_to_primary(self):
    state = {"version": 1, "devices": {"output": "alsa_out", "input": "alsa_in"},
             "micFx": {"enabled": False}}
    migrated = wavemix_fx.migrate_state(state, manifests, "1.1.0")
    self.assertEqual(migrated["devices"]["outputs"], ["alsa_out"])

  def test_existing_outputs_are_preserved(self):
    state = {"version": 2, "devices": {"output": "a", "outputs": ["a", "b"],
             "input": "in"}, "micFx": {"enabled": False, "chain": []}}
    migrated = wavemix_fx.migrate_state(state, manifests, "1.1.0")
    self.assertEqual(migrated["devices"]["outputs"], ["a", "b"])
    self.assertEqual(migrated["devices"]["output"], "a")

  def test_add_remove_move_toggle_and_instance_ids(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": []}}
    first = wavemix_fx.add_instance(state, manifests, "highpass")
    second = wavemix_fx.add_instance(state, manifests, "highpass")
    self.assertEqual(first["id"], "highpass-1")
    self.assertEqual(second["id"], "highpass-2")
    self.assertTrue(wavemix_fx.move_instance(state, "highpass-2", "up"))
    self.assertEqual(state["micFx"]["chain"][0]["id"], "highpass-2")
    self.assertTrue(wavemix_fx.toggle_instance(state, "highpass-2"))
    self.assertFalse(state["micFx"]["chain"][0]["enabled"])
    self.assertTrue(wavemix_fx.remove_instance(state, "highpass-2"))

  def test_set_control_clamps_and_rejects_unknown(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "pluginVersion": "1.0.0",
       "enabled": True, "controls": {}}]}}
    high = wavemix_fx.set_instance_control(state, manifests, "rnnoise-1", "vadThreshold", 500)
    self.assertEqual(high["value"], 99)
    self.assertIsNone(wavemix_fx.set_instance_control(state, manifests, "rnnoise-1", "nope", 1))

  def test_enabled_instances_assigns_fx_nodes_in_order(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True, "controls": {}},
      {"id": "highpass-1", "plugin": "highpass", "enabled": False, "controls": {}},
      {"id": "noisegate-1", "plugin": "noisegate", "enabled": True, "controls": {}}]}}
    nodes = [item["node"] for item in wavemix_fx.enabled_instances(state, manifests)]
    self.assertEqual(nodes, ["fx0", "fx1"])
    self.assertIsNone(wavemix_fx.node_for_instance(state, manifests, "highpass-1"))
```

`manifests` is the result of `discover_manifests(ROOT / "plugins", tmp_user_dir, "1.1.0")`; use a `setUpClass` fixture.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL with missing state functions.

- [ ] **Step 3: Implement the state model and hook migration into `load_state`**

Rules:

- `default_chain` uses manifests with `default: true`, available, no error, sorted by id; one instance each with `<id>-1`, `pluginVersion`, `enabled: true`, and `manifest_defaults`.
- `migrate_state`:
  - missing version = 1
  - version > 2 raises `FxError`
  - v1 with `micFx.controls` creates `rnnoise-1` using only keys valid in the RNNoise manifest, then fills missing keys with defaults
  - v1 without controls uses `default_chain`
  - always sets `version: 2` and ensures `micFx.enabled` exists
  - ensures `devices.outputs` is a non-empty list; if missing/empty, sets it
    to `[devices.output]`; if `devices.output` is missing from a non-empty
    list, moves the first entry into `devices.output`
  - preserves unknown fields
- `add_instance` rejects unknown/unavailable/error manifests; enforces `allowMultiple`; generates the lowest unused `<plugin>-<n>`; appends or inserts at `index`.
- `remove_instance`, `move_instance`, `toggle_instance` mutate the chain and return success.
- `set_instance_control` clamps display values using the manifest control spec, creates the controls map if needed, and returns `{instance, control, value}` or `None`.
- `enabled_instances` walks the chain, skips disabled or unavailable/error instances, assigns `fx0..` in order, and returns normalized entries.
- In `bin/wavemix`, after parsing the state JSON, call:
  `return fx.migrate_state(data, fx.discover_manifests(fx.bundled_dir(), fx.user_dir(), fx.WAVEMIX_VERSION), fx.WAVEMIX_VERSION)`
  using the default-dir helpers introduced in Task 2.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS for migration, instance mutation, clamping, and node assignment tests.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix bin/wavemix_fx.py tests/test_wavemix.py
git commit -m "feat: add effect chain state and v1 migration" -m "Introduce state v2 with an ordered effect chain, default-chain construction from manifests, instance ids, add/remove/move/bypass, control clamping, and rx-node assignment. Migrate old micFx.controls into a rnnoise-1 instance without losing values."
```

---

### Task 4: Chain compiler and config writer

**Files:**
- Modify: `bin/wavemix_fx.py`
- Modify: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: `enabled_instances`, `manifest_defaults`.
- Produces:
  - `GENERATED_MARKER: str`
  - `wavemix_fx.config_path() -> Path`
  - `wavemix_fx.render_config(state: dict, manifests: dict[str, dict], version: str) -> str`
  - `wavemix_fx.write_config(path: Path, content: str) -> bool`
  - `wavemix_fx.render_to_disk(state, manifests, version, path: Path | None = None) -> bool`

- [ ] **Step 1: Write the failing compiler tests**

Add `CompilerTests`:

```python
class CompilerTests(unittest.TestCase):
  def test_empty_chain_renders_only_marker(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": []}}
    text = wavemix_fx.render_config(state, manifests, "1.1.0")
    self.assertTrue(text.startswith(wavemix_fx.GENERATED_MARKER))
    self.assertNotIn("libpipewire-module-filter-chain", text)

  def test_two_effects_render_nodes_and_link(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True,
       "controls": {"vadThreshold": 60, "dryMix": 25}},
      {"id": "highpass-1", "plugin": "highpass", "enabled": True,
       "controls": {"freq": 80, "q": 0.707}}]}}
    text = wavemix_fx.render_config(state, manifests, "1.1.0")
    self.assertIn("name = fx0", text)
    self.assertIn('"VAD Threshold (%)" = 60', text)
    self.assertIn('"Dry Mix" = 0.250000', text)
    self.assertIn("name = fx1", text)
    self.assertIn('{ output = "fx0:Output" input = "fx1:In" }', text)
    self.assertIn('inputs = [ "fx0:Input" ]', text)
    self.assertIn('outputs = [ "fx1:Out" ]', text)
    self.assertIn('node.name = "wavemix_micfx.capture"', text)
    self.assertIn('audio.position = [ MONO ]', text)

  def test_disabled_and_unavailable_effects_are_skipped(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": False, "controls": {}},
      {"id": "missing-1", "plugin": "missing-plugin", "enabled": True, "controls": {}},
      {"id": "highpass-1", "plugin": "highpass", "enabled": True, "controls": {}}]}}
    text = wavemix_fx.render_config(state, manifests, "1.1.0")
    self.assertIn("name = fx0", text)
    self.assertNotIn("rnnoise", text)
    self.assertNotIn("missing", text)
    self.assertIn("name = fx1", text)

  def test_strings_with_spaces_and_punctuation_are_quoted(self):
    text = wavemix_fx.render_config(state_with_rnnoise, manifests, "1.1.0")
    self.assertIn('"VAD Grace Period (ms)"', text)

  def test_write_config_backs_up_handwritten_file_once(self):
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
      # Write "handwritten" to path; write_config returns True and creates one .bak-*.
      # Write the same content again; returns False and creates no second backup.
      # Write generated content; returns True and keeps the marker.

  def test_quotes_and_backslashes_are_escaped(self):
    # A manifest label containing a quote or backslash must render as an
    # escaped SPA string and must not break the generated config.
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL with missing `render_config`/`write_config`.

- [ ] **Step 3: Implement rendering and writing**

Implementation rules:

- `GENERATED_MARKER = "# Generated by Wavemix. Do not edit by hand; use `wavemix fx`."`
- `config_path()` resolves `${XDG_CONFIG_HOME:-~/.config}/pipewire/pipewire.conf.d/90-wavemix-micfx.conf`.
- `_spa_quote(text)` escapes backslashes, quotes, and newlines; use it for every string.
- `_spa_value(value)` renders strings, booleans, ints/floats, lists, and dicts into SPA syntax (`{ "key" = value ... }`).
- `render_config` builds the marker, a comment with core version and chain names, and when `enabled_instances` is non-empty a `context.modules` block with:
  - one node per enabled/available instance, named `fxN`
  - control values converted `raw = display / scale`; integer display values rounded; non-integer and `raw_float` written as floats
  - `links` between adjacent `fxN:output` and `fx(N+1):input`
  - `inputs = [ "fx0:<input>" ]`, `outputs = [ "fxN:<output>" ]`
  - `audio.rate = 48000`, `audio.position = [ MONO ]`
  - capture `wavemix_micfx.capture`, `node.autoconnect=false`, `node.passive=true`
  - playback `wavemix_micfx`, `node.autoconnect=false`, `node.passive=true`
- `write_config` returns `False` when the file content is already identical. When different, it backs up an existing file that lacks the marker to `90-wavemix-micfx.conf.bak-<timestamp>`, writes a temp file in the same directory, and `os.replace`s it. Return `True`.
- `render_to_disk` calls `render_config` and `write_config`; the CLI uses it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS for empty/single/two-effect rendering, skipping, quoting, and backup behavior.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix_fx.py tests/test_wavemix.py
git commit -m "feat: compile effect chains into the PipeWire config" -m "Render enabled effects as fx0.. nodes with explicit links, mono boundaries, and converted control values. Write the generated config atomically, keep a one-time backup of the old handwritten file, and skip disabled or unavailable effects."
```

---

### Task 5: Live controls and old micfx consolidation

**Files:**
- Modify: `bin/wavemix_fx.py`
- Modify: `bin/wavemix:304-423` (old micfx helpers), `bin/wavemix:624` (`up` override call), `bin/wavemix:924-960` (`cmd_micfx`)
- Modify: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: `enabled_instances`, `node_for_instance`, `manifest` control specs.
- Produces:
  - `wavemix_fx.parse_control_params(text: str) -> dict[str, float | int]`
  - `wavemix_fx.find_capture_node_id(run) -> int | None`
  - `wavemix_fx.live_control_values(run, node_id: int) -> dict[str, float | int]`
  - `wavemix_fx.set_live_control(run, node_id: int, node: str, control: dict, raw) -> None`
  - `wavemix_fx.apply_chain_controls(run, node_id: int | None, state: dict, manifests: dict[str, dict]) -> int`
  - `wavemix_fx.first_instance_of(state: dict, plugin_id: str) -> dict | None`

- [ ] **Step 1: Write the failing live-control tests**

Add `LiveControlTests`:

```python
SAMPLE_PARAMS = """
      String "fx0:VAD Threshold (%)"
      Int 50
      String "fx0:Dry Mix"
      Float 0.250000
      String "fx1:Freq"
      Float 80.000000
"""

class LiveControlTests(unittest.TestCase):
  def test_parse_control_params_keeps_node_prefix(self):
    values = wavemix_fx.parse_control_params(SAMPLE_PARAMS)
    self.assertEqual(values["fx0:VAD Threshold (%)"], 50)
    self.assertEqual(values["fx0:Dry Mix"], 0.25)
    self.assertEqual(values["fx1:Freq"], 80.0)

  def test_find_capture_node_id(self):
    def run(*args):
      return '[{"id": 34, "info": {"props": {"node.name": "wavemix_micfx.capture"}}}]'
    self.assertEqual(wavemix_fx.find_capture_node_id(run), 34)

  def test_set_live_control_quotes_param_and_formats_raw(self):
    calls = []
    def run(*args): calls.append(args)
    control = {"param": "Dry Mix", "integer": True, "raw_float": True, "scale": 100}
    wavemix_fx.set_live_control(run, 34, "fx0", control, 0.25)
    self.assertEqual(calls[0][:4], ("pw-cli", "set-param", "34", "Props"))
    self.assertIn('"fx0:Dry Mix" 0.250000', calls[0][4])

  def test_apply_chain_controls_skips_missing_node_and_disabled(self):
    calls = []
    def run(*args): calls.append(args)
    self.assertEqual(wavemix_fx.apply_chain_controls(run, None, state, manifests), 0)
    self.assertEqual(calls, [])
```

Also add a test that `apply_chain_controls` calls `set_live_control` for each enabled instance with stored values and skips bypassed instances.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL with missing live-control functions.

- [ ] **Step 3: Implement live controls and remove the duplicate RNNoise helpers**

Rules:

- `parse_control_params` reads `pw-cli enum-params` lines matching `String "<node>:<param>"` followed by `Int` or `Float`.
- `find_capture_node_id` parses `pw-dump` JSON and returns the id whose `node.name` is `wavemix_micfx.capture`.
- `set_live_control` builds `{ params = ["<node>:<param>" <raw>] }` with the same int/float rules as the compiler; use `pw-cli set-param`.
- `live_control_values` calls `parse_control_params` on `pw-cli enum-params <id> Props`.
- `apply_chain_controls` returns 0 when node id is `None`, otherwise iterates `enabled_instances`, resolves stored controls, and applies each one.
- `first_instance_of` returns the first chain entry with a given plugin id.
- In `bin/wavemix`, remove `MICFX_CONTROLS`, `parse_micfx_params`, `micfx_node_id`, `micfx_raw_value`, `micfx_display_value`, `micfx_clamped`, `_set_micfx_param`, `apply_micfx_control`, `apply_micfx_overrides`, `micfx_controls_snapshot`, and `set_micfx_control`. Replace the `up()` call with:
  `fx.apply_chain_controls(sh, fx.find_capture_node_id(sh), state, fx.discover_manifests(fx.bundled_dir(), fx.user_dir(), fx.WAVEMIX_VERSION))`.
- `cmd_micfx`:
  - `on|off|toggle` remains the master switch.
  - `controls` finds `first_instance_of(state, "rnnoise")`, reads live values, and prints the existing JSON shape.
  - `set` calls `fx.set_instance_control` for that instance, saves state, renders, then applies the live value if the node exists.
- Replace the old RNNoise unit tests with module-level tests; keep adapter tests for `cmd_micfx`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS for param parsing, node discovery, set-param formatting, override application, and the legacy `micfx` adapters.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix bin/wavemix_fx.py tests/test_wavemix.py
git commit -m "feat: wire live effect controls to the filter-chain" -m "Parse per-node filter-chain params, find the live capture node, set controls with pw-cli, reapply stored values on up(), and route the legacy micfx controls/set commands through the first RNNoise instance."
```

---

### Task 6: CLI fx commands

**Files:**
- Modify: `bin/wavemix` (parser, `cmd_fx`, `restart_audio`, `main`)
- Modify: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: all `wavemix_fx` functions from Tasks 2–5.
- Produces:
  - `wavemix fx plugins [--json]`
  - `wavemix fx state [--json]`
  - `wavemix fx add <plugin-id> [--index N]`
  - `wavemix fx remove <instance-id>`
  - `wavemix fx move <instance-id> up|down`
  - `wavemix fx toggle <instance-id>`
  - `wavemix fx set <instance-id> <control> <value>`
  - `wavemix fx enable|disable`
  - `wavemix fx render`
  - `wavemix fx apply`
  - `wavemix_fx.state_snapshot(state, manifests, version, running) -> dict`

- [ ] **Step 1: Write the failing CLI tests**

Add `CliFxTests`:

```python
class CliFxTests(unittest.TestCase):
  def test_fx_add_saves_renders_and_restarts(self):
    # Point STATE_FILE/CONFIG at TemporaryDirectory via monkeypatch.
    # Monkeypatch restart_audio to record calls.
    # Invoke wavemix.main(["fx", "add", "highpass"]).
    # Assert state chain contains highpass-1, config contains fx0,
    # and restart_audio was called once.

  def test_fx_set_does_not_restart(self):
    # Add rnnoise-1, call main(["fx", "set", "rnnoise-1", "vadThreshold", "60"]).
    # Assert state value is 60, config contains 60, restart_audio not called.

  def test_fx_state_json_contains_versions_and_chain(self):
    # Build a state with one rnnoise instance and monkeypatch running=True.
    # Capture stdout from main(["fx", "state", "--json"]).
    # Assert wavemixVersion, chain[0].plugin, plugin version, controls.

  def test_fx_state_reports_unavailable_plugin(self):
    # Add a manifest with a missing LADSPA file; fx state includes available false,
    # error/requires strings, and a GPU flag for Maxine.

  def test_micfx_controls_still_maps_to_first_rnnoise(self):
    # Call main(["micfx", "controls", "--json"]) with a rnnoise instance.
    # Assert the legacy JSON shape and values.
```

Also add a parser test that `--version` still works and `fx add` rejects a missing plugin with a non-zero exit.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL with unknown `fx` command / missing `cmd_fx`.

- [ ] **Step 3: Implement the CLI surface**

Rules:

- Change `main(argv: list[str] | None = None)` to pass `argv` to `build_parser().parse_args(argv)`.
- Add a top-level `fx` subparser with nested `action` choices: `plugins`, `state`, `add`, `remove`, `move`, `toggle`, `set`, `enable`, `disable`, `render`, `apply`.
- `restart_audio()` runs `systemctl --user restart pipewire pipewire-pulse wireplumber` with `subprocess.run`, returns `True`/`False`, and prints stderr on failure.
- `cmd_fx`:
  - loads/migrates state
  - discovers manifests with the default dirs
  - calls the module mutation function
  - saves state on mutation
  - calls `fx.render_to_disk`
  - calls `restart_audio` for `add/remove/move/toggle/apply`; not for `set/render/enable/disable`
  - prints concise confirmation or JSON
  - exits non-zero on `FxError`, unknown instance/control, unavailable plugin, or restart failure
- `state_snapshot` includes `wavemixVersion`, `enabled`, `running`, `chain` (instance, plugin, pluginVersion, versionChanged, enabled, available, error, gpu, node, controls with values/ranges/units), and `plugins` (manifest metadata).
- `fx enable|disable` updates `micFx.enabled`, saves, and calls the existing mic route rebuild (`up(state)`) without restarting PipeWire.
- `micfx controls|set` adapters delegate to the first RNNoise instance; `micfx on|off|toggle` remains the master.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS for add/set/state/unavailable/legacy tests.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix tests/test_wavemix.py
git commit -m "feat(cli): add effect chain commands and release versions" -m "Add fx plugins/state/add/remove/move/toggle/set/enable/disable/render/apply, JSON state for the popup, restart handling for structural changes, live-only control changes, and legacy micfx adapters that target the first RNNoise instance."
```

---

### Task 7: Installer, bundled manifests, and plugin packaging

**Files:**
- Modify: `install.sh`
- Modify: `bin/wavemix` (config path/`up` render integration if not already done)
- Delete: `extras/90-wavemix-micfx.conf`
- Modify: `tests/test_wavemix.py` (install layout unit checks if practical)

**Interfaces:**
- Consumes: `wavemix fx render`, `wavemix fx apply`, bundled manifests.
- Produces: an install that copies `bin/wavemix_fx.py` and `plugins/*.json`, syncs `~/.local/share/wavemix/plugins`, and loads the default chain.

- [ ] **Step 1: Write the failing install-layout test**

Add a test that reads `install.sh` and asserts it installs `bin/wavemix_fx.py`, copies `plugin/*`, and references `fx render`/`fx apply`:

```python
def test_installer_ships_effect_module_and_manifests(self):
    text = (ROOT / "install.sh").read_text()
    self.assertIn("wavemix_fx.py", text)
    self.assertIn("plugins", text)
    self.assertIn("fx render", text)
```

This is a guard test, not a substitute for manual install verification.

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL because the installer does not mention the module/plugins yet.

- [ ] **Step 3: Update the installer**

`install.sh`:

- install `bin/wavemix_fx.py` to `$bin_home/wavemix_fx.py` with `0644`
- sync bundled manifests:
  `rm -rf "$data_home/wavemix/plugins"` then `install -d` and `install -m 0644 "$repo"/plugins/*.json`
  where `$data_home=${XDG_DATA_HOME:-$HOME/.local/share}`
- call `"$bin_home/wavemix" fx render` before starting the service
- compare whether the config changed; if changed, call `"$bin_home/wavemix" fx apply` after the service starts (or call `fx apply` directly, which renders again)
- remove the old extras config from the repo; the installer must not reference it

`bin/wavemix`'s `up()` should call `fx.render_to_disk(state, manifests, fx.WAVEMIX_VERSION)` before linking, so a graph rebuild keeps the config current.

- [ ] **Step 4: Run the test and shell checks**

Run:

```bash
python3 -m unittest discover -s tests -v
bash -n install.sh
```

Expected: tests pass and `install.sh` parses.

- [ ] **Step 5: Commit**

```bash
git add install.sh bin/wavemix tests/test_wavemix.py && git rm extras/90-wavemix-micfx.conf
git commit -m "feat: install effect plugins and generated config" -m "Ship wavemix_fx.py and the bundled manifests, sync the bundled plugin directory, render the effect config before starting the service, and apply it once so the default chain loads. Remove the superseded extras config."
```

---

### Task 8: Multi-output graph engine

**Files:**
- Modify: `bin/wavemix` (`channel_target`, `ensure_send`, `apply_all_sends`, `graph_up`, `status`, `sanitize_devices`, `device_mute`)
- Modify: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: `devices.outputs`, `devices.output`, existing `sink_inputs()` and `sink_name_by_index()`.
- Produces:
  - `channel_targets(channel: dict, send: str, devices: dict) -> list[str]`
  - `streams_for(channel_id: str, send: str) -> list[dict]`
  - `ensure_send` creates one loopback per target
  - `apply_all_sends` applies the shared tag to every copy
  - `status` sends include `targets` and all-target liveness
  - `device_mute("output", state)` is true only when every selected output is muted

- [ ] **Step 1: Write the failing graph tests**

Add `MultiOutputGraphTests`:

```python
class MultiOutputGraphTests(unittest.TestCase):
  def test_channel_targets_returns_each_selected_output(self):
    devices = {"output": "a", "outputs": ["a", "b", "c"]}
    self.assertEqual(wavemix.channel_targets({"source": "apps"}, "output", devices),
                     ["a", "b", "c"])
    self.assertEqual(wavemix.channel_targets({"source": "apps"}, "input", devices),
                     [wavemix.STREAM_BUS])

  def test_channel_targets_dedupes_and_falls_back(self):
    self.assertEqual(wavemix.channel_targets({}, "output", {"outputs": ["a", "a"]}), ["a"])
    self.assertEqual(wavemix.channel_targets({}, "output", {"output": "a"}), ["a"])

  def test_ensure_send_creates_one_loopback_per_output(self):
    # Fake sink_inputs() returning one existing tagged stream for "a".
    # Expect load_module called once for "b", with sink=b and the same tag.
    ...

  def test_apply_all_sends_updates_every_copy(self):
    # Fake sink_inputs() returning two streams tagged "browser:output".
    # Expect set-sink-input-volume/mute for both indexes.
    ...

  def test_status_reports_output_targets_and_all_target_liveness(self):
    # A state with outputs ["a", "b"] and one live stream for each.
    # status JSON: sends.output.targets == ["a", "b"], live == True.
    ...

  def test_sanitize_devices_keeps_at_least_one_output(self):
    # devices.outputs contains a virtual/vanished name plus one hardware name.
    # The invalid entry is dropped and output is the remaining hardware name.
    ...

  def test_device_mute_is_true_only_when_all_outputs_are_muted(self):
    # a muted, b unmuted -> False; both muted -> True.
    ...
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL with missing `channel_targets`/`streams_for` and old single-output behavior.

- [ ] **Step 3: Implement the multi-output graph**

Rules:

- `channel_targets` returns the deduped `devices.outputs` for the output send,
  falling back to `[devices.output]` or `@DEFAULT_SINK@`; the input send stays
  `[STREAM_BUS]`.
- `streams_for` returns every sink input whose `wavemix` tag is
  `<channel>:<send>`.
- `ensure_send` gets the capture once, then for each target checks whether a
  tagged stream already targets that sink (map sink index to name), and creates
  only the missing loopbacks. Keep the existing muted creation.
- `apply_all_sends` maps tag → list of streams and applies the trimmed volume
  and mute to every stream for the tag.
- `graph_up` requires a live stream for every target of every channel send.
- `status` adds `targets` (selected sink names) and `liveTargets`; `live` is
  true only when all targets have streams. Keep `liveVolume`/`liveMuted` from
  the first stream for the existing UI.
- `sanitize_devices` filters `devices.outputs` to hardware names, falls back to
  the default sink/first hardware, and sets `devices.output` to the first
  entry. It returns True when anything changed.
- `device_mute("output", state)` returns True only when every selected output
  is muted.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS for target construction, per-target loopbacks, all-copy
volume/mute, status liveness, sanitization, and all-output mute semantics.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix tests/test_wavemix.py
git commit -m "feat: duplicate output sends across selected devices" -m "Build one loopback per selected hardware output, apply the shared send tag to every copy, report per-target liveness, sanitize vanished outputs while keeping at least one, and make the output mute state true only when all selected outputs are muted."
```

---

### Task 9: Multi-output CLI commands

**Files:**
- Modify: `bin/wavemix` (`cmd_device`, `cmd_devices`, `cmd_mute`, `cmd_mutes`, parser)
- Modify: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: the Task 8 graph and mute helpers.
- Produces:
  - `wavemix device output <name>`
  - `wavemix device output-add <name>`
  - `wavemix device output-remove <name>`
  - `devices --json` with `selected.outputs`
  - all-output `mutes` and `mute output on|off|toggle`

- [ ] **Step 1: Write the failing CLI tests**

Add `MultiOutputCliTests`:

```python
class MultiOutputCliTests(unittest.TestCase):
  def test_output_add_appends_and_rebuilds(self):
    # state outputs ["a"]; main(["device", "output-add", "b"]).
    # Assert outputs ["a","b"] and a rebuild/up call occurred.

  def test_output_remove_refuses_the_last_output(self):
    # state outputs ["a"]; main(["device", "output-remove", "a"]).
    # Assert non-zero exit or SystemExit, state unchanged, outputs still ["a"].

  def test_output_remove_keeps_the_primary(self):
    # state output "a", outputs ["a","b"]; remove "b".
    # Assert outputs ["a"], output "a".

  def test_devices_json_includes_selected_outputs(self):
    # Capture devices --json; assert selected.outputs == ["a","b"].

  def test_mute_toggle_applies_to_every_output(self):
    # a unmuted, b muted; mute output toggle.
    # Expect both set to muted.

  def test_mutes_reports_output_true_only_when_all_are_muted(self):
    # a muted, b unmuted -> {"output": false}; both muted -> true.
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL because the new device actions/JSON are missing.

- [ ] **Step 3: Implement the CLI surface**

Rules:

- Extend the `device` parser to accept `output`, `output-add`,
  `output-remove`, and `input`.
- `device output <name>` moves the name to the front of `devices.outputs`,
  preserves other selections, sets `devices.output`, validates hardware, saves,
  and rebuilds with `up(state)`.
- `output-add` appends a non-duplicate hardware device; `output-remove` removes
  one but rejects removing the last selection.
- `devices --json` adds `selected.outputs` while keeping
  `selected.output`.
- `cmd_mute` for output applies the action to every selected output; `toggle`
  computes the new state from `device_mute` (all-muted) and applies it to all.
  Input stays single-device.
- `cmd_mutes` returns the all-muted output boolean.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -v`
Expected: PASS for add/remove/last-output/JSON/mute-all tests.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix tests/test_wavemix.py
git commit -m "feat(cli): add multi-output device commands" -m "Add output-add/output-remove, preserve the primary when removing, reject removing the last output, expose selected.outputs in devices JSON, and apply mute/toggle to every selected output with all-muted status semantics."
```

---

### Task 10: Multi-output mixer UI

**Files:**
- Modify: `plugin/Panel.qml`

**Interfaces:**
- Consumes: `devices --json` `selected.outputs`, `device output-add/remove`.
- Produces: an **Also play to** checkbox list, an output-count label on send rows, and all-output speaker mute via the existing CLI.

- [ ] **Step 1: Manual baseline**

Open the mixer and confirm the current single **Output** dropdown and speaker toggle work.

- [ ] **Step 2: Add the additional-output picker**

- Keep the existing `ddOutput` primary dropdown.
- Add a `PanelSectionHeader` **Also play to** and a checkbox row for each
  hardware output that is not the primary.
- Add `deviceSelectedOutputs`, `outputIsSelected(name)`, and
  `toggleOutput(name)` QML helpers reading `devicesData.selected.outputs`.
- `toggleOutput` calls `device output-add`/`output-remove`, refreshes devices,
  and shows a short notice when the last output cannot be removed.
- Show `out ×N` in the `SendRow` label when `selected.outputs.length > 1`.
- Keep the speaker toggle and bar icon behavior; the CLI now mutes all selected
  outputs.
- Do not change the Default out dropdown or the output fader/meter logic.

- [ ] **Step 3: Verify manually**

- Select two outputs; confirm both receive the mix and the per-channel `out`
  fader/mute affects both.
- Add/remove an output; confirm the other keeps playing and the last output
  cannot be removed.
- Confirm the speaker icon mutes/unmutes all selected outputs.
- Confirm the default-sink dropdown and per-channel meters still work.
- Confirm no QML errors in the journal.

- [ ] **Step 4: Commit**

```bash
git add plugin/Panel.qml
git commit -m "feat(plugin): add the multi-output mixer picker" -m "Keep the primary Output dropdown, add an Also play to checkbox list for additional hardware outputs, show the selected-output count on out rows, and surface the last-output rejection notice. Speaker mute now covers every selected output through the CLI."
```

---

### Task 11: Effects popup data plumbing and master switch

**Files:**
- Modify: `plugin/Panel.qml`

**Interfaces:**
- Consumes: `wavemix fx state --json`, `wavemix fx enable|disable`.
- Produces: `fxData`, `fxStateProc`, `fxOpen`, master switch, popup header/footer with version.

- [ ] **Step 1: Manual baseline**

Run: `omarchy-shell mnisyif.wavemix micfx` and confirm the current popup opens and the RNNoise sliders work. Record the current layout as the baseline.

- [ ] **Step 2: Replace the popup data source**

In `plugin/Panel.qml`:

- replace `fxControlsProc` with `fxStateProc` running `[root.bin, "fx", "state", "--json"]`
- store `root.fxData`; add `fxChain` and `fxPlugins` derived properties
- on `fxOpen`, call `refreshFxState()`; keep the existing `micfx`/`fx` IPC open methods and keep `micfxset` as a compatibility hook for the first RNNoise instance
- change the popup header to `EFFECTS` and add `Wavemix <version>` from `fxData.wavemixVersion`
- render a master `ToggleSwitch` bound to `fxData.enabled`, calling `run(["fx", "enable"])` or `run(["fx", "disable"])` and refreshing state
- show `No effects. Add one.` when the chain is empty
- do not add chain editing yet; render a read-only list of `fxChain` rows

- [ ] **Step 3: Verify manually**

Run: `omarchy restart shell`, open the popup via IPC, and check:

- header/version appear
- master switch reflects the current enabled state
- the chain list shows the migrated RNNoise instance
- no QML errors in the journal

- [ ] **Step 4: Commit**

```bash
git add plugin/Panel.qml
git commit -m "feat(plugin): load the effect chain into the popup" -m "Switch the popup to wavemix fx state JSON, show the core version and master effects switch, and render the migrated chain read-only. No chain mutations yet."
```

---

### Task 12: Effects popup chain editing

**Files:**
- Modify: `plugin/Panel.qml`

**Interfaces:**
- Consumes: `fx add/remove/move/toggle`, `fx plugins`/`fx state` data.
- Produces: add-effect list, bypass/remove/up/down actions, applying state.

- [ ] **Step 1: Manual baseline**

Open the popup and confirm the read-only chain from Task 11.

- [ ] **Step 2: Add chain editing**

- Add a selected row highlight and an Add effect button.
- Add an add-effect subview listing `fxPlugins` with name, description, version, source, GPU badge, `requires`, and disabled styling for unavailable entries.
- Add per-row buttons: bypass toggle (`fx toggle <id>`), remove (`fx remove <id>`), move up/down (`fx move <id> up|down`).
- After each mutation, show `Applying… audio restarts briefly`, call the CLI through `run`, then refresh `fx state` after the command completes.
- Keep the popup open during the restart; show an error and keep the state editable if the command fails.
- Refresh state after the command queue drains; use a one-shot timer or the existing process-exit signal.

- [ ] **Step 3: Verify manually**

- Add high-pass and noise gate; verify rows appear in order.
- Reorder, bypass, remove; verify the list and audio follow.
- Confirm no QML errors and the popup survives the PipeWire restart.
- Confirm the master switch and the existing per-channel meters still work.

- [ ] **Step 4: Commit**

```bash
git add plugin/Panel.qml
git commit -m "feat(plugin): add effect chain editing" -m "Add the add-effect list, bypass/remove/reorder controls, applying state, and error handling for structural chain changes. The popup refreshes fx state after each command."
```

---

### Task 13: Effects popup settings and version/GPU display

**Files:**
- Modify: `plugin/Panel.qml`

**Interfaces:**
- Consumes: per-instance controls from `fx state`, `fx set`.
- Produces: selected-effect sliders, version-change warning, GPU/install-hint rows.

- [ ] **Step 1: Manual baseline**

Open the popup, add/select an effect, and confirm the chain actions work.

- [ ] **Step 2: Add selected-effect settings**

- Render the selected instance's `controls` with `PanelSlider` rows (label, value + unit, range/step).
- Apply on release via `run(["fx", "set", instance, key, String(value)])`, updating the local model optimistically so the knob does not snap back.
- Disable sliders when the instance is bypassed or unavailable.
- Show the plugin version and a `versionChanged` warning; show `gpu` badges and `requires`/`error` text for unavailable plugins.
- Keep the existing list/selected-row behavior and the master switch.

- [ ] **Step 3: Verify manually**

- Select RNNoise, change each control, and confirm `pw-cli enum-params` changes with no audio restart.
- Select high-pass and noise gate; confirm their controls match the manifest ranges.
- Remove/misconfigure a manifest; confirm the row shows the error/hint and does not crash the popup.
- Confirm the popup shows core/plugin versions and GPU badges where applicable.
- Confirm no QML errors.

- [ ] **Step 4: Commit**

```bash
git add plugin/Panel.qml
git commit -m "feat(plugin): add effect settings and version-aware rows" -m "Render per-instance controls with live fx set updates, disable settings for bypassed/unavailable effects, and show plugin versions, version-change warnings, GPU badges, and install hints in the popup."
```

---

### Task 14: Documentation, end-to-end verification, and release

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/specs/2026-11-06-wavemix-effect-plugins-design.md` only if implementation exposed a contradiction
- Tag: `v1.1.0`

- [ ] **Step 1: Update the README**

Document:

- the Effects popup and chain editing
- the multi-output picker and all-output mute behavior
- manifest locations and the schema
- bundled effects and their versions
- GPU/neural effects: DeepFilterNet and Maxine LADSPA, with the runtime/LADSPA_PATH/quantum caveats
- `wavemix --version`, `fx plugins`, `fx state`, and all `fx` commands
- state migration from the old `micFx.controls`
- version tracking and `minWavemix`
- the test command

- [ ] **Step 2: Run the full automated suite**

Run:

```bash
python3 -m unittest discover -s tests -v
python3 -m py_compile bin/wavemix bin/wavemix_fx.py
bash -n install.sh
```

Expected: all tests pass, both Python files compile, installer parses.

- [ ] **Step 3: Run the end-to-end manual verification**

- Run `./install.sh`.
- Restart the shell if needed.
- Confirm `wavemix --version` and the popup version.
- Add RNNoise, high-pass, and noise gate; reorder, bypass, remove; confirm audio and routing.
- Select two hardware outputs; confirm both receive the same mix, the per-channel
  output fader/mute affects both, and the last output cannot be removed.
- Confirm the speaker toggle mutes every selected output.
- Change controls live; confirm no restart.
- Restart PipeWire; confirm the chain and controls persist.
- If available, add DeepFilterNet and confirm it runs; otherwise confirm the install hint.
- If available, add Maxine and confirm the GPU badge/intensity slider; otherwise confirm the install hint.
- Break a manifest intentionally; confirm the error row and that the rest of the chain works.
- Confirm the mic bus, virtual mic, and per-channel meters still work.
- Check the journal for Wavemix QML errors.

- [ ] **Step 4: Final commit and tag**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document the effect plugin system" -m "Describe the Effects popup, manifests, bundled and GPU effects, version tracking, migration, and all fx commands. Include the final 1.1.0 changelog entry."
git tag v1.1.0
```

---

## Self-Review

- **Spec coverage:** Tasks 1–6 cover versioning, manifests, state migration, compilation, live controls, CLI; Task 7 covers installation; Tasks 8–10 cover multi-device output; Tasks 11–13 cover the popup; Task 14 covers docs and release.
- **Step scan:** Each task has a failing test, a failing run, implementation rules, a passing run, and a commit. QML tasks use explicit manual checks because no QML harness exists.
- **Type consistency:** `wavemix_fx` names are consistent across tasks (`discover_manifests`, `migrate_state`, `enabled_instances`, `render_config`, `apply_chain_controls`, `state_snapshot`). Multi-output uses `devices.outputs`, `channel_targets`, `streams_for`, and the existing `channel:output` tag. The CLI keeps `micfx` adapters while the new surface is `fx`.
- **Review focus coverage:** Task 2 pins incompatible/missing GPU manifests; Task 3 pins v1 migration and `devices.outputs`; Task 4 pins skipping/quoting; Task 5 pins missing-node control behavior; Task 6 pins state JSON/legacy adapters; Tasks 8–9 pin vanished/last-output and mixed-mute behavior.
- **Proportion:** The plan names decisions and tests; implementation bodies are left to the executor.
