import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("wavemix", str(ROOT / "bin" / "wavemix"))
SPEC = importlib.util.spec_from_loader("wavemix", LOADER)
wavemix = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(wavemix)

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


def manifest_data(ident, version="1.0.0", **overrides):
  data = {
    "schemaVersion": 1, "id": ident, "version": version,
    "name": ident.title(), "type": "builtin", "label": "noisegate",
    "input": "In", "output": "Out", "controls": [],
  }
  data.update(overrides)
  return data


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

  def test_unsupported_schema_version_is_unavailable(self):
    with tempfile.TemporaryDirectory() as tmp:
      root = Path(tmp)
      bundled = root / "bundled"
      bundled.mkdir()
      (bundled / "future.json").write_text(
        json.dumps(manifest_data("future", schemaVersion=2)),
        encoding="utf-8")
      (bundled / "ok.json").write_text(
        json.dumps(manifest_data("ok")), encoding="utf-8")

      manifests = wavemix_fx.discover_manifests(
        bundled, root / "user", "1.1.0")

      self.assertFalse(manifests["future"]["available"])
      self.assertIn("schemaVersion", manifests["future"]["error"])
      self.assertIn("2", manifests["future"]["error"])
      self.assertTrue(manifests["ok"]["available"])
      self.assertIsNone(manifests["ok"]["error"])

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
    with tempfile.TemporaryDirectory() as tmp:
      root = Path(tmp)
      bundled = root / "bundled"
      user = root / "user"
      bundled.mkdir()
      user.mkdir()
      (bundled / "demo.json").write_text(
        json.dumps(manifest_data("demo", "1.0.0")), encoding="utf-8")
      (user / "demo.json").write_text(
        json.dumps(manifest_data("demo", "2.0.0")), encoding="utf-8")

      manifests = wavemix_fx.discover_manifests(bundled, user, "1.1.0")

      self.assertEqual(manifests["demo"]["version"], "2.0.0")
      self.assertEqual(manifests["demo"]["source"], "user")

  def test_invalid_user_manifest_is_kept_as_an_error_row(self):
    with tempfile.TemporaryDirectory() as tmp:
      root = Path(tmp)
      bundled = root / "bundled"
      user = root / "user"
      bundled.mkdir()
      user.mkdir()
      (bundled / "demo.json").write_text(
        json.dumps(manifest_data("demo", "1.0.0")), encoding="utf-8")
      broken = manifest_data("demo", "2.0.0", controls=[{
        "key": "freq", "param": "Freq", "label": "Freq",
        "min": 10, "max": 1, "step": 1, "default": 5,
      }])
      (user / "demo.json").write_text(json.dumps(broken), encoding="utf-8")

      manifests = wavemix_fx.discover_manifests(bundled, user, "1.1.0")

      self.assertEqual(manifests["demo"]["source"], "bundled")
      user_rows = [m for m in manifests.values() if m["source"] == "user"]
      self.assertEqual(len(user_rows), 1)
      self.assertFalse(user_rows[0]["available"])
      self.assertIn("range", user_rows[0]["error"])

  def test_null_config_value_is_unavailable_and_others_stay_available(self):
    with tempfile.TemporaryDirectory() as tmp:
      root = Path(tmp)
      bundled = root / "bundled"
      user = root / "user"
      bundled.mkdir()
      user.mkdir()
      (bundled / "demo.json").write_text(
        json.dumps(manifest_data("demo", "1.0.0")), encoding="utf-8")
      broken = manifest_data("broken", "1.0.0", config={"x": None})
      (user / "broken.json").write_text(json.dumps(broken), encoding="utf-8")

      manifests = wavemix_fx.discover_manifests(bundled, user, "1.1.0")

      self.assertTrue(manifests["demo"]["available"])
      self.assertIsNone(manifests["demo"]["error"])
      self.assertFalse(manifests["broken"]["available"])
      self.assertIn("config", manifests["broken"]["error"])

  def test_non_finite_and_unsupported_config_values_are_rejected(self):
    for value, message in ((float("inf"), "finite"),
                           ({"nested": [None]}, "nested[0]"),
                           (object(), "unsupported")):
      with self.subTest(value=value):
        manifest = wavemix_fx.normalize_manifest(
          manifest_data("bad", config={"x": value}),
          source="user", path=Path("/tmp/bad.json"), version="1.1.0")
        self.assertFalse(manifest["available"])
        self.assertIn(message, manifest["error"])

  def test_bundled_manifests_validate_and_rnnoise_is_default(self):
    with tempfile.TemporaryDirectory() as tmp:
      manifests = wavemix_fx.discover_manifests(
        ROOT / "plugins", Path(tmp) / "user", "1.1.0")

    expected = {"rnnoise", "highpass", "noisegate",
                "deepfilternet", "maxine-denoise"}
    self.assertEqual(set(manifests), expected)
    for ident in expected:
      manifest = manifests[ident]
      self.assertEqual(manifest["id"], ident)
      self.assertEqual(manifest["schemaVersion"], 1)
      self.assertEqual(manifest["source"], "bundled")
      self.assertTrue(
        manifest["error"] is None
        or manifest["error"].startswith("LADSPA plugin not found:"),
        f"{ident}: {manifest['error']}")
    self.assertTrue(manifests["rnnoise"]["default"])
    self.assertEqual(
      {control["key"] for control in manifests["rnnoise"]["controls"]},
      {"vadThreshold", "vadGrace", "retroactiveGrace", "dryMix"})
    self.assertEqual(manifests["highpass"]["label"], "bq_highpass")

  def test_bundled_control_and_gpu_values_are_pinned(self):
    with tempfile.TemporaryDirectory() as tmp:
      manifests = wavemix_fx.discover_manifests(
        ROOT / "plugins", Path(tmp) / "user", "1.1.0")

    rnnoise = {c["key"]: c for c in manifests["rnnoise"]["controls"]}
    vad_grace = rnnoise["vadGrace"]
    self.assertEqual(
      (vad_grace["min"], vad_grace["max"], vad_grace["step"],
       vad_grace["unit"]), (0, 1000, 10, " ms"))

    highpass = {c["key"]: c for c in manifests["highpass"]["controls"]}
    self.assertEqual(
      (highpass["freq"]["min"], highpass["freq"]["max"],
       highpass["freq"]["step"], highpass["freq"]["default"],
       highpass["freq"]["unit"]), (20, 500, 5, 80, " Hz"))
    self.assertEqual(
      (highpass["q"]["min"], highpass["q"]["max"], highpass["q"]["step"],
       highpass["q"]["default"], highpass["q"]["integer"]),
      (0.1, 5, 0.1, 0.707, False))

    deepfilter = manifests["deepfilternet"]
    self.assertFalse(deepfilter["gpu"])
    self.assertEqual(deepfilter["requires"], "Install deepfilternet-ladspa")

    maxine = manifests["maxine-denoise"]
    self.assertTrue(maxine["gpu"])
    self.assertEqual(
      maxine["requires"],
      "Install broadcast-maxine-ladspa and the NVIDIA Maxine runtime; "
      "add ~/.local/lib/ladspa to LADSPA_PATH if needed")

  def test_missing_maxine_ladspa_is_unavailable_but_listed(self):
    with tempfile.TemporaryDirectory() as tmp, \
         patch.dict(os.environ, {"HOME": tmp}):
      manifests = wavemix_fx.discover_manifests(
        ROOT / "plugins", Path(tmp) / "user", "1.1.0")
      maxine = manifests["maxine-denoise"]

      self.assertFalse(maxine["available"])
      self.assertTrue(maxine["plugin"].startswith(tmp))
      self.assertIn("broadcast-maxine-ladspa", maxine["requires"])
      rows = {row["id"]: row for row in wavemix_fx.plugin_list(manifests)}
      self.assertIn("maxine-denoise", rows)
      self.assertFalse(rows["maxine-denoise"]["available"])

  def test_manifest_defaults_returns_display_defaults(self):
    manifest = wavemix_fx.normalize_manifest(
      manifest_data("demo", controls=[
        {"key": "freq", "param": "Freq", "min": 20, "max": 500,
         "step": 5, "default": 80},
        {"key": "q", "param": "Q", "min": 0.1, "max": 5,
         "step": 0.1, "default": 0.707},
      ]), source="bundled", path=Path("/tmp/demo.json"), version="1.1.0")

    self.assertEqual(wavemix_fx.manifest_defaults(manifest),
                     {"freq": 80, "q": 0.707})

  def test_plugin_list_has_stable_fields(self):
    manifest = wavemix_fx.normalize_manifest(
      manifest_data("demo"), source="bundled",
      path=Path("/tmp/demo.json"), version="1.1.0")

    row = wavemix_fx.plugin_list({"demo": manifest})[0]

    self.assertEqual(set(row), {
      "id", "name", "description", "version", "schemaVersion", "minWavemix",
      "source", "available", "gpu", "requires", "error", "type",
      "allowMultiple", "controls"})

  def test_plugin_list_includes_type_gpu_and_control_defaults(self):
    manifests = wavemix_fx.discover_manifests(
      ROOT / "plugins", Path("/nonexistent"), "1.1.0")
    rows = {row["id"]: row for row in wavemix_fx.plugin_list(manifests)}
    highpass = rows["highpass"]
    self.assertEqual(highpass["type"], "builtin")
    self.assertFalse(highpass["gpu"])
    self.assertTrue(highpass["allowMultiple"])
    freq = next(c for c in highpass["controls"] if c["key"] == "freq")
    self.assertEqual(freq["default"], 80)
    self.assertEqual(freq["min"], 20)
    self.assertEqual(freq["max"], 500)
    self.assertTrue(rows["maxine-denoise"]["gpu"])
    self.assertEqual(rows["rnnoise"]["type"], "ladspa")


class StateTests(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls._user_dir = tempfile.TemporaryDirectory()
    cls.manifests = wavemix_fx.discover_manifests(
      ROOT / "plugins", Path(cls._user_dir.name), "1.1.0")
    # Keep the suite hermetic: pretend the RNNoise LADSPA is installed even
    # when this host does not have it.
    cls.manifests["rnnoise"]["available"] = True
    cls.manifests["rnnoise"]["error"] = None

  @classmethod
  def tearDownClass(cls):
    cls._user_dir.cleanup()

  def test_v1_controls_migrate_to_rnnoise_instance(self):
    state = {"version": 1, "micFx": {"enabled": True,
             "controls": {"vadThreshold": 35, "dryMix": 50}}}
    migrated = wavemix_fx.migrate_state(state, self.manifests, "1.1.0")
    self.assertEqual(migrated["version"], 2)
    self.assertEqual(migrated["micFx"]["chain"][0]["id"], "rnnoise-1")
    self.assertEqual(migrated["micFx"]["chain"][0]["pluginVersion"], self.manifests["rnnoise"]["version"])
    self.assertEqual(migrated["micFx"]["chain"][0]["controls"]["vadThreshold"], 35)
    self.assertEqual(migrated["micFx"]["chain"][0]["controls"]["dryMix"], 50)

  def test_v1_controls_are_retained_when_rnnoise_manifest_is_missing(self):
    controls = {"vadThreshold": 35, "dryMix": 50}
    state = {"version": 1, "micFx": {"enabled": True, "controls": controls}}
    migrated = wavemix_fx.migrate_state(state, {}, "1.1.0")
    self.assertEqual(migrated["version"], 2)
    self.assertEqual(migrated["micFx"]["controls"], controls)
    self.assertEqual(
      migrated["micFx"]["chain"][0]["controls"], controls)

  def test_v1_without_controls_uses_default_chain(self):
    state = {"version": 1, "micFx": {"enabled": False}}
    migrated = wavemix_fx.migrate_state(state, self.manifests, "1.1.0")
    self.assertEqual([i["plugin"] for i in migrated["micFx"]["chain"]], ["rnnoise"])

  def test_newer_state_version_is_rejected(self):
    with self.assertRaises(wavemix_fx.FxError):
      wavemix_fx.migrate_state({"version": 3}, self.manifests, "1.1.0")

  def test_newer_state_version_as_string_or_float_is_rejected(self):
    for version in ("3", 3.0):
      with self.subTest(version=version):
        with self.assertRaises(wavemix_fx.FxError):
          wavemix_fx.migrate_state({"version": version}, self.manifests, "1.1.0")

  def test_missing_outputs_migrates_to_primary(self):
    state = {"version": 1, "devices": {"output": "alsa_out", "input": "alsa_in"},
             "micFx": {"enabled": False}}
    migrated = wavemix_fx.migrate_state(state, self.manifests, "1.1.0")
    self.assertEqual(migrated["devices"]["outputs"], ["alsa_out"])

  def test_existing_outputs_are_preserved(self):
    state = {"version": 2, "devices": {"output": "a", "outputs": ["a", "b"],
             "input": "in"}, "micFx": {"enabled": False, "chain": []}}
    migrated = wavemix_fx.migrate_state(state, self.manifests, "1.1.0")
    self.assertEqual(migrated["devices"]["outputs"], ["a", "b"])
    self.assertEqual(migrated["devices"]["output"], "a")

  def test_add_remove_move_toggle_and_instance_ids(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": []}}
    first = wavemix_fx.add_instance(state, self.manifests, "highpass")
    second = wavemix_fx.add_instance(state, self.manifests, "highpass")
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
    high = wavemix_fx.set_instance_control(
      state, self.manifests, "rnnoise-1", "vadThreshold", 500)
    self.assertEqual(high["value"], 99)
    self.assertIsNone(wavemix_fx.set_instance_control(
      state, self.manifests, "rnnoise-1", "nope", 1))

  def test_set_control_preserves_sub_hundredth_steps(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "noisegate-1", "plugin": "noisegate",
       "enabled": True, "controls": {}}]}}
    for value in (0.001, 0.005):
      with self.subTest(value=value):
        result = wavemix_fx.set_instance_control(
          state, self.manifests, "noisegate-1", "attack", value)
        self.assertEqual(result["value"], value)

  def test_enabled_instances_assigns_fx_nodes_in_order(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True, "controls": {}},
      {"id": "highpass-1", "plugin": "highpass", "enabled": False, "controls": {}},
      {"id": "noisegate-1", "plugin": "noisegate", "enabled": True, "controls": {}}]}}
    nodes = [item["node"] for item in wavemix_fx.enabled_instances(
      state, self.manifests)]
    self.assertEqual(nodes, ["fx0", "fx1"])
    self.assertIsNone(wavemix_fx.node_for_instance(
      state, self.manifests, "highpass-1"))


class ChainReplaceTests(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls._user_dir = tempfile.TemporaryDirectory()
    cls.manifests = wavemix_fx.discover_manifests(
      ROOT / "plugins", Path(cls._user_dir.name), "1.1.0")
    cls.manifests["rnnoise"]["available"] = True
    cls.manifests["rnnoise"]["error"] = None

  @classmethod
  def tearDownClass(cls):
    cls._user_dir.cleanup()

  def state_with_rnnoise(self):
    return {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "pluginVersion": "1.0.0",
       "enabled": True, "controls": {"vadThreshold": 60}, "custom": "keep"}]}}

  def test_replace_chain_reorders_and_preserves_controls(self):
    state = self.state_with_rnnoise()
    state["micFx"]["chain"].append({
      "id": "highpass-1", "plugin": "highpass", "pluginVersion": "1.0.0",
      "enabled": True, "controls": {"freq": 120}})
    chain = wavemix_fx.replace_chain(state, self.manifests, [
      {"instance": "highpass-1", "plugin": "highpass"},
      {"instance": "rnnoise-1", "plugin": "rnnoise"}])
    self.assertEqual([item["id"] for item in chain],
                     ["highpass-1", "rnnoise-1"])
    self.assertEqual(chain[1]["controls"]["vadThreshold"], 60)
    self.assertEqual(chain[1]["custom"], "keep")

  def test_replace_chain_adds_new_with_controls_and_unique_id(self):
    state = self.state_with_rnnoise()
    chain = wavemix_fx.replace_chain(state, self.manifests, [
      {"instance": "rnnoise-1", "plugin": "rnnoise"},
      {"instance": "", "plugin": "highpass",
       "controls": {"freq": 200}}])
    self.assertEqual(chain[1]["id"], "highpass-1")
    self.assertEqual(chain[1]["controls"]["freq"], 200)

  def test_replace_chain_rejects_unknown_instance_and_plugin_mismatch(self):
    state = self.state_with_rnnoise()
    with self.assertRaises(wavemix_fx.FxError):
      wavemix_fx.replace_chain(state, self.manifests, [
        {"instance": "missing-1", "plugin": "rnnoise"}])
    with self.assertRaises(wavemix_fx.FxError):
      wavemix_fx.replace_chain(state, self.manifests, [
        {"instance": "rnnoise-1", "plugin": "highpass"}])

  def test_replace_chain_rejects_unavailable_new_plugin(self):
    state = self.state_with_rnnoise()
    with self.assertRaises(wavemix_fx.FxError):
      wavemix_fx.replace_chain(state, self.manifests, [
        {"instance": "", "plugin": "maxine-denoise"}])

  def test_replace_chain_rejects_duplicate_ids(self):
    state = self.state_with_rnnoise()
    with self.assertRaises(wavemix_fx.FxError):
      wavemix_fx.replace_chain(state, self.manifests, [
        {"instance": "rnnoise-1", "plugin": "rnnoise"},
        {"instance": "rnnoise-1", "plugin": "rnnoise"}])

  def test_replace_chain_toggles_bypass(self):
    state = self.state_with_rnnoise()
    chain = wavemix_fx.replace_chain(state, self.manifests, [
      {"instance": "rnnoise-1", "plugin": "rnnoise", "enabled": False}])
    self.assertFalse(chain[0]["enabled"])


class CompilerTests(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls._user_dir = tempfile.TemporaryDirectory()
    cls.manifests = wavemix_fx.discover_manifests(
      ROOT / "plugins", Path(cls._user_dir.name), "1.1.0")
    # Keep the suite hermetic: pretend the RNNoise LADSPA is installed even
    # when this host does not have it.
    cls.manifests["rnnoise"]["available"] = True
    cls.manifests["rnnoise"]["error"] = None
    cls.state_with_rnnoise = {
      "version": 2,
      "micFx": {"enabled": True, "chain": [
        {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True,
         "controls": {}}]},
    }

  @classmethod
  def tearDownClass(cls):
    cls._user_dir.cleanup()

  def test_empty_chain_renders_only_marker(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": []}}
    text = wavemix_fx.render_config(state, self.manifests, "1.1.0")
    self.assertTrue(text.startswith(wavemix_fx.GENERATED_MARKER))
    self.assertNotIn("libpipewire-module-filter-chain", text)

  def test_two_effects_render_nodes_and_link(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True,
       "controls": {"vadThreshold": 60, "dryMix": 25}},
      {"id": "highpass-1", "plugin": "highpass", "enabled": True,
       "controls": {"freq": 80, "q": 0.707}}]}}
    text = wavemix_fx.render_config(state, self.manifests, "1.1.0")
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
      {"id": "missing-1", "plugin": "missing-plugin", "enabled": True,
       "controls": {}},
      {"id": "highpass-1", "plugin": "highpass", "enabled": True,
       "controls": {}}]}}
    text = wavemix_fx.render_config(state, self.manifests, "1.1.0")
    # Only highpass survives, so it is the first (and only) node: fx0.
    self.assertIn("name = fx0", text)
    self.assertNotIn("name = fx1", text)
    self.assertNotIn("rnnoise", text)
    self.assertNotIn("missing", text)

  def test_master_off_still_compiles_a_non_empty_chain(self):
    state = {"version": 2, "micFx": {"enabled": False, "chain": [
      {"id": "highpass-1", "plugin": "highpass", "enabled": True,
       "controls": {}}]}}
    text = wavemix_fx.render_config(state, self.manifests, "1.1.0")
    self.assertIn("libpipewire-module-filter-chain", text)
    self.assertIn("name = fx0", text)

  def test_master_off_empty_chain_renders_no_module(self):
    state = {"version": 2, "micFx": {"enabled": False, "chain": []}}
    text = wavemix_fx.render_config(state, self.manifests, "1.1.0")
    self.assertNotIn("libpipewire-module-filter-chain", text)

  def test_unrenderable_instance_is_skipped(self):
    broken = dict(self.manifests["highpass"])
    broken["config"] = {"x": None}
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "broken-1", "plugin": "broken", "enabled": True, "controls": {}},
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True,
       "controls": {}}]}}
    manifests = dict(self.manifests, broken=broken)

    text = wavemix_fx.render_config(state, manifests, "1.1.0")

    self.assertIn("libpipewire-module-filter-chain", text)
    self.assertNotIn("broken", text)
    self.assertNotIn("name = fx0", text)
    self.assertIn("name = fx1", text)
    self.assertIn('inputs = [ "fx1:Input" ]', text)
    self.assertIn('outputs = [ "fx1:Output" ]', text)

  def test_strings_with_spaces_and_punctuation_are_quoted(self):
    text = wavemix_fx.render_config(
      self.state_with_rnnoise, self.manifests, "1.1.0")
    self.assertIn('"VAD Grace Period (ms)"', text)

  def test_missing_controls_use_manifest_defaults(self):
    text = wavemix_fx.render_config(
      self.state_with_rnnoise, self.manifests, "1.1.0")
    self.assertIn('"VAD Threshold (%)" = 50', text)
    self.assertIn('"Dry Mix" = 0.000000', text)

  def test_quotes_and_backslashes_are_escaped(self):
    manifest = wavemix_fx.normalize_manifest(
      manifest_data("demo", label='bad"label\\path'),
      source="user", path=Path("/tmp/demo.json"), version="1.1.0")
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "demo-1", "plugin": "demo", "enabled": True,
       "controls": {}}]}}

    text = wavemix_fx.render_config(state, {"demo": manifest}, "1.1.0")

    self.assertIn('label = "bad\\"label\\\\path"', text)
    self.assertNotIn('bad"label', text)

  def test_config_path_uses_xdg_config_home(self):
    with tempfile.TemporaryDirectory() as tmp, \
         patch.dict(os.environ, {"XDG_CONFIG_HOME": tmp}):
      self.assertEqual(
        wavemix_fx.config_path(),
        Path(tmp) / "pipewire" / "pipewire.conf.d" /
        "90-wavemix-micfx.conf")

  def test_write_config_backs_up_handwritten_file_once(self):
    with tempfile.TemporaryDirectory() as tmp:
      path = Path(tmp) / "90-wavemix-micfx.conf"
      path.write_text("handwritten config\n", encoding="utf-8")
      generated = wavemix_fx.render_config(
        self.state_with_rnnoise, self.manifests, "1.1.0")

      self.assertTrue(wavemix_fx.write_config(path, generated))
      backups = sorted(path.parent.glob(path.name + ".bak-*"))
      self.assertEqual(len(backups), 1)
      self.assertEqual(backups[0].read_text(encoding="utf-8"),
                       "handwritten config\n")
      self.assertTrue(path.read_text(encoding="utf-8").startswith(
        wavemix_fx.GENERATED_MARKER))

      self.assertFalse(wavemix_fx.write_config(path, generated))
      self.assertEqual(
        len(list(path.parent.glob(path.name + ".bak-*"))), 1)

      # A later handwritten edit is not backed up a second time.
      path.write_text("handwritten again\n", encoding="utf-8")
      self.assertTrue(wavemix_fx.write_config(path, generated + "# v2\n"))
      self.assertEqual(
        len(list(path.parent.glob(path.name + ".bak-*"))), 1)

  def test_render_to_disk_writes_and_reports_changes(self):
    with tempfile.TemporaryDirectory() as tmp:
      path = Path(tmp) / "90-wavemix-micfx.conf"

      self.assertTrue(wavemix_fx.render_to_disk(
        self.state_with_rnnoise, self.manifests, "1.1.0", path))
      self.assertIn("libpipewire-module-filter-chain",
                    path.read_text(encoding="utf-8"))
      self.assertFalse(wavemix_fx.render_to_disk(
        self.state_with_rnnoise, self.manifests, "1.1.0", path))


SAMPLE_PARAMS = """
      String "fx0:VAD Threshold (%)"
      Int 50
      String "fx0:Dry Mix"
      Float 0.250000
      String "fx1:Freq"
      Float 80.000000
"""


class LiveControlTests(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls._user_dir = tempfile.TemporaryDirectory()
    cls.manifests = wavemix_fx.discover_manifests(
      ROOT / "plugins", Path(cls._user_dir.name), "1.1.0")
    # Keep the suite hermetic: pretend the RNNoise LADSPA is installed even
    # when this host does not have it.
    cls.manifests["rnnoise"]["available"] = True
    cls.manifests["rnnoise"]["error"] = None

  @classmethod
  def tearDownClass(cls):
    cls._user_dir.cleanup()

  def test_parse_control_params_keeps_node_prefix(self):
    values = wavemix_fx.parse_control_params(SAMPLE_PARAMS)
    self.assertEqual(values["fx0:VAD Threshold (%)"], 50)
    self.assertEqual(values["fx0:Dry Mix"], 0.25)
    self.assertEqual(values["fx1:Freq"], 80.0)

  def test_parse_control_params_ignores_params_without_a_node(self):
    text = SAMPLE_PARAMS + '\n      String "channelmix.normalize"\n      Bool false\n'
    values = wavemix_fx.parse_control_params(text)
    self.assertNotIn("channelmix.normalize", values)

  def test_find_capture_node_id(self):
    def run(*args):
      self.assertEqual(args, ("pw-dump",))
      return '[{"id": 34, "info": {"props": {"node.name": "wavemix_micfx.capture"}}}]'
    self.assertEqual(wavemix_fx.find_capture_node_id(run), 34)

  def test_find_capture_node_id_returns_none_when_missing(self):
    self.assertIsNone(wavemix_fx.find_capture_node_id(lambda *args: "[]"))
    self.assertIsNone(wavemix_fx.find_capture_node_id(lambda *args: "not json"))

  def test_live_control_values_requests_the_props_param(self):
    calls = []
    def run(*args):
      calls.append(args)
      return SAMPLE_PARAMS
    values = wavemix_fx.live_control_values(run, 34)
    self.assertEqual(calls[0], ("pw-cli", "enum-params", "34", "Props"))
    self.assertEqual(values["fx0:Dry Mix"], 0.25)

  def test_set_live_control_quotes_param_and_formats_raw(self):
    calls = []
    def run(*args): calls.append(args)
    control = {"param": "Dry Mix", "integer": True, "raw_float": True, "scale": 100}
    self.assertTrue(
      wavemix_fx.set_live_control(run, 34, "fx0", control, 0.25))
    self.assertEqual(calls[0][:4], ("pw-cli", "set-param", "34", "Props"))
    self.assertIn('"fx0:Dry Mix" 0.250000', calls[0][4])

  def test_set_live_control_reports_a_missing_node(self):
    calls = []
    def run(*args): calls.append(args)
    control = {"param": "Dry Mix", "raw_float": True}
    self.assertFalse(
      wavemix_fx.set_live_control(run, None, "fx0", control, 0.25))
    self.assertEqual(calls, [])

  def test_set_live_control_writes_integral_values_as_ints(self):
    calls = []
    def run(*args): calls.append(args)
    control = {"param": "VAD Threshold (%)", "integer": True}
    wavemix_fx.set_live_control(run, 34, "fx0", control, 60)
    self.assertIn('"fx0:VAD Threshold (%)" 60', calls[0][4])

  def chain_state(self):
    return {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True,
       "controls": {"vadThreshold": 60, "dryMix": 25}},
      {"id": "highpass-1", "plugin": "highpass", "enabled": False,
       "controls": {"freq": 120}}]}}

  def test_apply_chain_controls_skips_missing_node_and_disabled(self):
    calls = []
    def run(*args): calls.append(args)
    self.assertEqual(
      wavemix_fx.apply_chain_controls(run, None, self.chain_state(), self.manifests),
      0)
    self.assertEqual(calls, [])

  @patch.object(wavemix_fx, "set_live_control")
  def test_apply_chain_controls_applies_stored_values_and_skips_bypassed(
      self, set_control):
    self.assertEqual(
      wavemix_fx.apply_chain_controls(
        lambda *args: "", 34, self.chain_state(), self.manifests),
      2)
    self.assertEqual(
      [(call.args[2], call.args[3]["param"], call.args[4])
       for call in set_control.call_args_list],
      [("fx0", "VAD Threshold (%)", 60), ("fx0", "Dry Mix", 0.25)])

  @patch.object(wavemix_fx, "set_live_control")
  def test_apply_chain_controls_ignores_unknown_stored_keys(self, set_control):
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True,
       "controls": {"gone": 10}}]}}
    self.assertEqual(
      wavemix_fx.apply_chain_controls(
        lambda *args: "", 34, state, self.manifests), 0)
    set_control.assert_not_called()

  def test_apply_chain_controls_clamps_out_of_range_stored_values(self):
    calls = []
    def run(*args): calls.append(args)
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True,
       "controls": {"vadThreshold": 500, "dryMix": -50}}]}}
    self.assertEqual(
      wavemix_fx.apply_chain_controls(run, 34, state, self.manifests), 2)
    payloads = [call[4] for call in calls]
    self.assertTrue(any(
      '"fx0:VAD Threshold (%)" 99' in payload for payload in payloads))
    self.assertTrue(any(
      '"fx0:Dry Mix" 0.000000' in payload for payload in payloads))

  def test_first_instance_of_returns_first_matching_chain_entry(self):
    state = {"micFx": {"chain": [
      {"id": "highpass-1", "plugin": "highpass"},
      {"id": "rnnoise-1", "plugin": "rnnoise"},
      {"id": "rnnoise-2", "plugin": "rnnoise"}]}}
    self.assertEqual(wavemix_fx.first_instance_of(state, "rnnoise")["id"],
                     "rnnoise-1")
    self.assertIsNone(wavemix_fx.first_instance_of(state, "noisegate"))


class MicfxCommandTests(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls._user_dir = tempfile.TemporaryDirectory()
    cls.manifests = wavemix_fx.discover_manifests(
      ROOT / "plugins", Path(cls._user_dir.name), "1.1.0")
    cls.manifests["rnnoise"]["available"] = True
    cls.manifests["rnnoise"]["error"] = None

  @classmethod
  def tearDownClass(cls):
    cls._user_dir.cleanup()

  def state(self):
    return {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True,
       "controls": {"vadThreshold": 55, "vadGrace": 200,
                    "retroactiveGrace": 0, "dryMix": 10}}]}}

  def args(self, *argv):
    return wavemix.build_parser().parse_args(["micfx", *argv])

  def test_controls_reads_live_values_for_the_first_rnnoise(self):
    output = io.StringIO()
    with patch.object(wavemix, "load_state", return_value=self.state()), \
         patch.object(wavemix, "mic_fx_available", return_value=True), \
         patch.object(wavemix.fx, "discover_manifests",
                      return_value=self.manifests), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=34), \
         patch.object(wavemix, "sh", return_value=SAMPLE_PARAMS), \
         contextlib.redirect_stdout(output):
      wavemix.cmd_micfx(self.args("controls", "--json"))

    out = json.loads(output.getvalue())
    self.assertEqual(set(out), {"enabled", "available", "running", "controls"})
    self.assertTrue(out["running"])
    values = {item["key"]: item["value"] for item in out["controls"]}
    self.assertEqual(values["vadThreshold"], 50)
    self.assertEqual(values["dryMix"], 25)
    self.assertEqual(values["vadGrace"], 200)

  def test_controls_falls_back_to_stored_values_when_node_is_missing(self):
    output = io.StringIO()
    with patch.object(wavemix, "load_state", return_value=self.state()), \
         patch.object(wavemix, "mic_fx_available", return_value=True), \
         patch.object(wavemix.fx, "discover_manifests",
                      return_value=self.manifests), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=None), \
         patch.object(wavemix, "sh") as sh, \
         contextlib.redirect_stdout(output):
      wavemix.cmd_micfx(self.args("controls", "--json"))

    out = json.loads(output.getvalue())
    self.assertFalse(out["running"])
    values = {item["key"]: item["value"] for item in out["controls"]}
    self.assertEqual(values["vadThreshold"], 55)
    self.assertEqual(values["dryMix"], 10)
    sh.assert_not_called()

  def test_set_stores_renders_and_applies_to_the_first_rnnoise(self):
    state = self.state()
    output = io.StringIO()
    with patch.object(wavemix, "load_state", return_value=state), \
         patch.object(wavemix, "save_state") as save, \
         patch.object(wavemix, "graph_lock", contextlib.nullcontext), \
         patch.object(wavemix.fx, "discover_manifests",
                      return_value=self.manifests), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=34), \
         patch.object(wavemix.fx, "render_to_disk") as render, \
         patch.object(wavemix, "sh") as sh, \
         contextlib.redirect_stdout(output):
      wavemix.cmd_micfx(self.args("set", "dryMix", "25"))

    self.assertEqual(state["micFx"]["chain"][0]["controls"]["dryMix"], 25)
    save.assert_called_once_with(state)
    render.assert_called_once()
    self.assertEqual(sh.call_args.args[:4], ("pw-cli", "set-param", "34", "Props"))
    self.assertIn('"fx0:Dry Mix" 0.250000', sh.call_args.args[4])
    self.assertIn("Dry mix = 25%", output.getvalue())

  def test_set_maps_to_the_first_rnnoise_node_not_the_first_chain_node(self):
    state = {"version": 2, "micFx": {"enabled": True, "chain": [
      {"id": "highpass-1", "plugin": "highpass", "enabled": True,
       "controls": {"freq": 80}},
      {"id": "rnnoise-1", "plugin": "rnnoise", "enabled": True,
       "controls": {"dryMix": 10}}]}}
    with patch.object(wavemix, "load_state", return_value=state), \
         patch.object(wavemix, "save_state"), \
         patch.object(wavemix, "graph_lock", contextlib.nullcontext), \
         patch.object(wavemix.fx, "discover_manifests",
                      return_value=self.manifests), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=34), \
         patch.object(wavemix.fx, "render_to_disk"), \
         patch.object(wavemix, "sh") as sh, \
         contextlib.redirect_stdout(io.StringIO()):
      wavemix.cmd_micfx(self.args("set", "dryMix", "25"))

    self.assertIn('"fx1:Dry Mix" 0.250000', sh.call_args.args[4])

  def test_set_json_reports_applied_true_when_the_node_is_live(self):
    state = self.state()
    output = io.StringIO()
    with patch.object(wavemix, "load_state", return_value=state), \
         patch.object(wavemix, "save_state"), \
         patch.object(wavemix, "graph_lock", contextlib.nullcontext), \
         patch.object(wavemix.fx, "discover_manifests",
                      return_value=self.manifests), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=34), \
         patch.object(wavemix.fx, "render_to_disk"), \
         patch.object(wavemix, "sh"), \
         contextlib.redirect_stdout(output):
      wavemix.cmd_micfx(self.args("set", "dryMix", "25", "--json"))

    out = json.loads(output.getvalue())
    self.assertTrue(out["applied"])
    self.assertEqual(out["instance"], "rnnoise-1")
    self.assertEqual(out["control"], "dryMix")
    self.assertEqual(out["value"], 25)

  def test_set_renders_while_holding_the_graph_lock(self):
    state = self.state()
    seen = []

    @contextlib.contextmanager
    def lock():
      seen.append("lock")
      try:
        yield
      finally:
        seen.append("unlock")

    def render(*args):
      seen.append("render")

    with patch.object(wavemix, "load_state", return_value=state), \
         patch.object(wavemix, "save_state"), \
         patch.object(wavemix, "graph_lock", lock), \
         patch.object(wavemix.fx, "discover_manifests",
                      return_value=self.manifests), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=None), \
         patch.object(wavemix.fx, "render_to_disk", side_effect=render), \
         patch.object(wavemix, "sh"), \
         contextlib.redirect_stdout(io.StringIO()):
      wavemix.cmd_micfx(self.args("set", "dryMix", "25"))

    self.assertEqual(seen[:3], ["lock", "render", "unlock"])

  def test_set_stores_without_applying_when_the_node_is_missing(self):
    state = self.state()
    output = io.StringIO()
    with patch.object(wavemix, "load_state", return_value=state), \
         patch.object(wavemix, "save_state"), \
         patch.object(wavemix, "graph_lock", contextlib.nullcontext), \
         patch.object(wavemix.fx, "discover_manifests",
                      return_value=self.manifests), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=None), \
         patch.object(wavemix.fx, "render_to_disk"), \
         patch.object(wavemix, "sh") as sh, \
         contextlib.redirect_stdout(output):
      wavemix.cmd_micfx(self.args("set", "vadGrace", "500", "--json"))

    self.assertEqual(state["micFx"]["chain"][0]["controls"]["vadGrace"], 500)
    sh.assert_not_called()
    out = json.loads(output.getvalue())
    self.assertFalse(out["applied"])
    self.assertEqual(out["control"], "vadGrace")
    self.assertEqual(out["value"], 500)

  def test_on_off_toggle_flip_the_master_switch_and_rebuild(self):
    cases = (("on", False, True), ("off", True, False),
             ("toggle", False, True), ("toggle", True, False))
    for action, before, after in cases:
      with self.subTest(action=action, before=before):
        state = {"version": 2, "micFx": {"enabled": before, "chain": []}}
        output = io.StringIO()
        with patch.object(wavemix, "load_state", return_value=state), \
             patch.object(wavemix, "save_state") as save, \
             patch.object(wavemix, "graph_lock", contextlib.nullcontext), \
             patch.object(wavemix, "up") as up, \
             patch.object(wavemix, "mic_fx_available", return_value=True), \
             contextlib.redirect_stdout(output):
          wavemix.cmd_micfx(self.args(action))

        self.assertEqual(state["micFx"]["enabled"], after)
        save.assert_called_once_with(state)
        up.assert_called_once_with(state)
        self.assertIn("mic fx on" if after else "mic fx off",
                      output.getvalue())


class CliFxTests(unittest.TestCase):
  def setUp(self):
    self._temp = tempfile.TemporaryDirectory()
    self.addCleanup(self._temp.cleanup)
    self.root = Path(self._temp.name)
    env = patch.dict(os.environ, {
      "XDG_CONFIG_HOME": str(self.root / "config"),
      "XDG_DATA_HOME": str(self.root / "data"),
    })
    env.start()
    self.addCleanup(env.stop)

    self.state_file = self.root / "wavemix" / "state.json"
    self.state_file.parent.mkdir(parents=True, exist_ok=True)
    self.config = self.root / "config" / "pipewire" / "pipewire.conf.d" \
        / "90-wavemix-micfx.conf"
    for name, value in (("STATE_FILE", self.state_file),
                        ("STATE_DIR", self.state_file.parent),
                        ("MICFX_CONF", self.config)):
      patcher = patch.object(wavemix, name, value)
      patcher.start()
      self.addCleanup(patcher.stop)

    user = self.root / "user-plugins"
    self.manifests = wavemix_fx.discover_manifests(
      ROOT / "plugins", user, wavemix_fx.WAVEMIX_VERSION)
    self.manifests["rnnoise"]["available"] = True
    self.manifests["rnnoise"]["error"] = None
    discover = patch.object(
      wavemix.fx, "discover_manifests", return_value=self.manifests)
    discover.start()
    self.addCleanup(discover.stop)

  def write_state(self, enabled=True, chain=None, input="@DEFAULT_SOURCE@"):
    data = {
      "version": 2,
      "devices": {"output": "@DEFAULT_SINK@",
                  "outputs": ["@DEFAULT_SINK@"],
                  "input": input},
      "channels": [], "rules": {}, "defaults": {},
      "micFx": {"enabled": enabled, "chain": chain or []},
    }
    self.state_file.write_text(json.dumps(data), encoding="utf-8")
    return data

  def rnnoise_instance(self):
    return {"id": "rnnoise-1", "plugin": "rnnoise",
            "pluginVersion": self.manifests["rnnoise"]["version"],
            "enabled": True,
            "controls": {"vadThreshold": 50, "vadGrace": 200,
                         "retroactiveGrace": 0, "dryMix": 0}}

  def test_fx_add_saves_renders_and_restarts(self):
    self.write_state(enabled=True, chain=[])
    restart = Mock(return_value=True)
    with patch.object(wavemix, "restart_audio", restart), \
         contextlib.redirect_stdout(io.StringIO()):
      self.assertEqual(wavemix.main(["fx", "add", "highpass"]), 0)

    saved = json.loads(self.state_file.read_text(encoding="utf-8"))
    self.assertEqual([item["id"] for item in saved["micFx"]["chain"]],
                     ["highpass-1"])
    text = self.config.read_text(encoding="utf-8")
    self.assertIn("name = fx0", text)
    self.assertIn('"Freq" = 80', text)
    restart.assert_called_once_with()

  def test_fx_add_hints_when_effects_are_off(self):
    self.write_state(enabled=False, chain=[])
    output = io.StringIO()
    with patch.object(wavemix, "restart_audio", Mock(return_value=True)), \
         contextlib.redirect_stdout(output):
      self.assertEqual(wavemix.main(["fx", "add", "highpass"]), 0)

    text = output.getvalue()
    self.assertIn("effects are off", text)
    self.assertIn("wavemix fx enable", text)

  def test_fx_enable_links_an_already_loaded_chain_without_restart(self):
    self.write_state(enabled=False, chain=[self.rnnoise_instance()],
                     input="alsa_in")
    restart = Mock(return_value=True)
    with patch.object(wavemix, "restart_audio", restart), \
         patch.object(wavemix, "sanitize_devices", Mock(return_value=False)), \
         patch.object(wavemix, "unload_all"), \
         patch.object(wavemix, "ensure_buses"), \
         patch.object(wavemix, "ensure_defaults"), \
         patch.object(wavemix, "ensure_mic_bus_feed") as feed, \
         patch.object(wavemix, "set_mic_fx_link") as link, \
         patch.object(wavemix, "set_mic_fx_playback_link") as playback, \
         patch.object(wavemix, "raw_mic_outputs",
                      return_value=["alsa_in:capture_MONO"]), \
         patch.object(wavemix, "apply_all_sends"), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=34), \
         patch.object(wavemix.fx, "apply_chain_controls"), \
         contextlib.redirect_stdout(io.StringIO()):
      self.assertEqual(wavemix.main(["fx", "enable"]), 0)

    link.assert_called_once_with("alsa_in", True)
    playback.assert_called_once_with()
    feed.assert_not_called()
    restart.assert_not_called()
    self.assertIn("libpipewire-module-filter-chain",
                  self.config.read_text(encoding="utf-8"))

  def test_fx_set_does_not_restart(self):
    self.write_state(enabled=True, chain=[self.rnnoise_instance()])
    restart = Mock(return_value=True)
    with patch.object(wavemix, "restart_audio", restart), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=None), \
         contextlib.redirect_stdout(io.StringIO()):
      self.assertEqual(
        wavemix.main(["fx", "set", "rnnoise-1", "vadThreshold", "60"]), 0)

    saved = json.loads(self.state_file.read_text(encoding="utf-8"))
    self.assertEqual(
      saved["micFx"]["chain"][0]["controls"]["vadThreshold"], 60)
    self.assertIn('"VAD Threshold (%)" = 60',
                  self.config.read_text(encoding="utf-8"))
    restart.assert_not_called()

  def test_fx_set_json_reports_applied_false_when_node_is_missing(self):
    self.write_state(enabled=True, chain=[self.rnnoise_instance()])
    output = io.StringIO()
    with patch.object(wavemix.fx, "find_capture_node_id", return_value=None), \
         contextlib.redirect_stdout(output):
      self.assertEqual(
        wavemix.main(
          ["fx", "set", "rnnoise-1", "vadThreshold", "60", "--json"]), 0)

    out = json.loads(output.getvalue())
    self.assertFalse(out["applied"])
    self.assertEqual(out["instance"], "rnnoise-1")
    self.assertEqual(out["control"], "vadThreshold")
    self.assertEqual(out["value"], 60)

  def test_fx_state_json_contains_versions_and_chain(self):
    self.write_state(enabled=True, chain=[self.rnnoise_instance()])
    output = io.StringIO()
    with patch.object(wavemix.fx, "find_capture_node_id", return_value=34), \
         contextlib.redirect_stdout(output):
      self.assertEqual(wavemix.main(["fx", "state", "--json"]), 0)

    out = json.loads(output.getvalue())
    self.assertEqual(out["wavemixVersion"], wavemix_fx.WAVEMIX_VERSION)
    self.assertTrue(out["enabled"])
    self.assertTrue(out["running"])
    self.assertIn("plugins", out)
    entry = out["chain"][0]
    self.assertEqual(entry["instance"], "rnnoise-1")
    self.assertEqual(entry["plugin"], "rnnoise")
    self.assertEqual(entry["type"], "ladspa")
    self.assertEqual(entry["pluginVersion"],
                     self.manifests["rnnoise"]["version"])
    self.assertFalse(entry["versionChanged"])
    self.assertEqual(entry["node"], "fx0")
    self.assertTrue(entry["available"])
    controls = {item["key"]: item for item in entry["controls"]}
    self.assertEqual(controls["vadThreshold"]["value"], 50)
    self.assertEqual(controls["vadThreshold"]["min"], 0)
    self.assertEqual(controls["vadThreshold"]["max"], 99)
    self.assertEqual(controls["vadThreshold"]["unit"], "%")

  def test_fx_state_reports_unavailable_plugin(self):
    maxine = self.manifests["maxine-denoise"]
    self.assertFalse(maxine["available"])
    self.write_state(enabled=True, chain=[{
      "id": "maxine-denoise-1", "plugin": "maxine-denoise",
      "pluginVersion": maxine["version"], "enabled": True, "controls": {},
    }])
    output = io.StringIO()
    with patch.object(wavemix.fx, "find_capture_node_id", return_value=None), \
         contextlib.redirect_stdout(output):
      self.assertEqual(wavemix.main(["fx", "state", "--json"]), 0)

    out = json.loads(output.getvalue())
    row = next(item for item in out["plugins"]
               if item["id"] == "maxine-denoise")
    self.assertFalse(row["available"])
    self.assertIn("LADSPA plugin not found", row["error"])
    self.assertIn("broadcast-maxine-ladspa", row["requires"])
    self.assertTrue(row["gpu"])
    entry = out["chain"][0]
    self.assertFalse(entry["available"])
    self.assertIn("LADSPA plugin not found", entry["error"])
    self.assertTrue(entry["gpu"])

  def test_micfx_controls_still_maps_to_first_rnnoise(self):
    self.write_state(enabled=True, chain=[self.rnnoise_instance()])
    output = io.StringIO()
    with patch.object(wavemix.fx, "find_capture_node_id", return_value=None), \
         contextlib.redirect_stdout(output):
      self.assertEqual(wavemix.main(["micfx", "controls", "--json"]), 0)

    out = json.loads(output.getvalue())
    self.assertEqual(set(out), {"enabled", "available", "running", "controls"})
    self.assertTrue(out["enabled"])
    self.assertFalse(out["running"])
    values = {item["key"]: item["value"] for item in out["controls"]}
    self.assertEqual(values["vadThreshold"], 50)
    self.assertEqual(values["vadGrace"], 200)
    self.assertEqual(values["dryMix"], 0)

  def test_fx_add_rejects_unknown_plugin_with_nonzero_exit(self):
    self.write_state(enabled=True, chain=[])
    with contextlib.redirect_stderr(io.StringIO()):
      code = wavemix.main(["fx", "add", "does-not-exist"])
    self.assertNotEqual(code, 0)

  def test_version_flag_still_works(self):
    output = io.StringIO()
    with contextlib.redirect_stdout(output), \
         self.assertRaises(SystemExit) as raised:
      wavemix.main(["--version"])
    self.assertEqual(raised.exception.code, 0)
    self.assertEqual(output.getvalue().strip(),
                     f"wavemix {wavemix_fx.WAVEMIX_VERSION}")

  def test_fx_enable_disable_rebuild_routes_without_restart(self):
    for action, before, after in (("enable", False, True),
                                  ("disable", True, False)):
      with self.subTest(action=action):
        self.write_state(enabled=before, chain=[])
        restart = Mock(return_value=True)
        with patch.object(wavemix, "restart_audio", restart), \
             patch.object(wavemix, "up") as up, \
             contextlib.redirect_stdout(io.StringIO()):
          self.assertEqual(wavemix.main(["fx", action]), 0)

        saved = json.loads(self.state_file.read_text(encoding="utf-8"))
        self.assertEqual(saved["micFx"]["enabled"], after)
        up.assert_called_once()
        self.assertEqual(up.call_args.args[0]["micFx"]["enabled"], after)
        restart.assert_not_called()


  def commit(self, payload, restart=True):
    stdin = io.StringIO(json.dumps(payload) + "\n")
    output = io.StringIO()
    restart_mock = Mock(return_value=restart)
    with patch.object(wavemix.sys, "stdin", stdin), \
         patch.object(wavemix, "restart_audio", restart_mock), \
         contextlib.redirect_stdout(output):
      code = wavemix.main(["fx", "commit", "--stdin", "--json"])
    return code, output.getvalue(), restart_mock

  def test_fx_commit_replaces_chain_and_restarts_once(self):
    self.write_state(enabled=True, chain=[self.rnnoise_instance()])
    code, out, restart = self.commit({"chain": [
      {"instance": "rnnoise-1", "plugin": "rnnoise", "enabled": False},
      {"instance": "", "plugin": "highpass", "controls": {"freq": 120}}]})
    self.assertEqual(code, 0)
    result = json.loads(out)
    self.assertTrue(result["ok"])
    self.assertTrue(result["restarted"])
    saved = json.loads(self.state_file.read_text(encoding="utf-8"))
    self.assertEqual([i["id"] for i in saved["micFx"]["chain"]],
                     ["rnnoise-1", "highpass-1"])
    self.assertFalse(saved["micFx"]["chain"][0]["enabled"])
    self.assertEqual(saved["micFx"]["chain"][1]["controls"]["freq"], 120)
    self.assertIn('"Freq" = 120', self.config.read_text(encoding="utf-8"))
    restart.assert_called_once_with()

  def test_fx_commit_render_failure_leaves_state_untouched(self):
    self.write_state(enabled=True, chain=[self.rnnoise_instance()])
    before = self.state_file.read_text(encoding="utf-8")
    with patch.object(wavemix.fx, "render_to_disk",
                      side_effect=wavemix.fx.FxError("render failed")):
      code, out, restart = self.commit({"chain": []})
    self.assertNotEqual(code, 0)
    self.assertFalse(json.loads(out)["ok"])
    self.assertEqual(self.state_file.read_text(encoding="utf-8"), before)
    restart.assert_not_called()

  def test_fx_commit_restart_failure_reports_not_restarted(self):
    self.write_state(enabled=True, chain=[self.rnnoise_instance()])
    code, out, restart = self.commit({"chain": []}, restart=False)
    self.assertEqual(code, 0)
    result = json.loads(out)
    self.assertTrue(result["ok"])
    self.assertFalse(result["restarted"])
    self.assertEqual(json.loads(
      self.state_file.read_text(encoding="utf-8"))["micFx"]["chain"], [])

  def test_fx_commit_rejects_malformed_json(self):
    self.write_state(enabled=True, chain=[])
    stdin = io.StringIO("{not json\n")
    output = io.StringIO()
    with patch.object(wavemix.sys, "stdin", stdin), \
         contextlib.redirect_stdout(output):
      code = wavemix.main(["fx", "commit", "--stdin", "--json"])
    self.assertNotEqual(code, 0)
    self.assertFalse(json.loads(output.getvalue())["ok"])


class UpReapplyTests(unittest.TestCase):
  def test_up_reapplies_stored_chain_controls(self):
    state = {"version": 2,
             "devices": {"output": "out", "outputs": ["out"],
                         "input": "alsa_in"},
             "channels": [], "defaults": {}, "rules": {},
             "micFx": {"enabled": True, "chain": []}}
    manifests = {}
    with patch.multiple(
        wavemix,
        sanitize_devices=Mock(return_value=False),
        unload_all=Mock(),
        ensure_buses=Mock(),
        ensure_defaults=Mock(),
        set_mic_fx_link=Mock(),
        set_mic_fx_playback_link=Mock(),
        ensure_mic_bus_feed=Mock(),
        apply_all_sends=Mock()), \
        patch.object(wavemix.fx, "find_capture_node_id", return_value=34), \
        patch.object(wavemix.fx, "discover_manifests",
                     return_value=manifests), \
        patch.object(wavemix.fx, "render_to_disk"), \
        patch.object(wavemix.fx, "apply_chain_controls") as apply_controls:
      wavemix.up(state)

    apply_controls.assert_called_once()
    args = apply_controls.call_args.args
    self.assertIs(args[0], wavemix.sh)
    self.assertEqual(args[1], 34)
    self.assertIs(args[2], state)
    self.assertIs(args[3], manifests)

  def test_up_renders_the_effect_config_before_linking(self):
    state = {"version": 2,
             "devices": {"output": "out", "outputs": ["out"],
                         "input": "alsa_in"},
             "channels": [], "defaults": {}, "rules": {},
             "micFx": {"enabled": True, "chain": []}}
    manifests = {}
    events = []

    def render(*args):
      events.append(("render", args))

    def link(*args):
      events.append(("link", args))

    with patch.multiple(
        wavemix,
        sanitize_devices=Mock(return_value=False),
        unload_all=Mock(),
        ensure_buses=Mock(),
        ensure_defaults=Mock(),
        set_mic_fx_link=Mock(side_effect=link),
        set_mic_fx_playback_link=Mock(),
        ensure_mic_bus_feed=Mock(),
        apply_all_sends=Mock()), \
        patch.object(wavemix.fx, "find_capture_node_id", return_value=34), \
        patch.object(wavemix.fx, "discover_manifests",
                     return_value=manifests), \
        patch.object(wavemix.fx, "render_to_disk",
                     side_effect=render), \
        patch.object(wavemix.fx, "apply_chain_controls"):
      wavemix.up(state)

    self.assertEqual(events[0][0], "render")
    self.assertEqual(events[0][1], (state, manifests, wavemix.fx.WAVEMIX_VERSION))
    self.assertEqual(events[1][0], "link")


class MicFxRoutingTests(unittest.TestCase):
  def state(self, chain, enabled=True):
    return {"version": 2,
            "devices": {"output": "out", "outputs": ["out"],
                        "input": "alsa_in"},
            "channels": [{"id": "mic", "name": "Mic", "source": "mic",
                          "output": {"on": False, "volume": 50},
                          "input": {"on": True, "volume": 100}}],
            "defaults": {}, "rules": {},
            "micFx": {"enabled": enabled, "chain": chain}}

  def manifests(self, available=True):
    return {"highpass": {"id": "highpass", "available": available,
                         "error": None if available else "plugin missing"}}

  def chain(self, enabled=True):
    return [{"id": "highpass-1", "plugin": "highpass", "enabled": enabled,
             "controls": {}}]

  def run_up(self, state, manifests, capture=34,
             raw_outputs=("alsa_in:capture_MONO",)):
    names = ("sanitize_devices", "unload_all", "ensure_buses",
             "ensure_defaults", "set_mic_fx_link",
             "set_mic_fx_playback_link", "ensure_mic_bus_feed",
             "ensure_channel_sink", "ensure_send", "apply_all_sends",
             "raw_mic_outputs")
    mocks = {name: Mock() for name in names}
    mocks["sanitize_devices"].return_value = False
    mocks["raw_mic_outputs"].return_value = list(raw_outputs)
    with patch.multiple(wavemix, **mocks), \
        patch.object(wavemix.fx, "find_capture_node_id",
                     return_value=capture), \
        patch.object(wavemix.fx, "discover_manifests",
                     return_value=manifests), \
        patch.object(wavemix.fx, "render_to_disk"), \
        patch.object(wavemix.fx, "apply_chain_controls"):
      wavemix.up(state)
    return mocks

  def assert_raw_path(self, mocks, mic="alsa_in"):
    mocks["set_mic_fx_link"].assert_called_once_with(mic, False)
    mocks["ensure_mic_bus_feed"].assert_called_once_with(mic)
    mocks["set_mic_fx_playback_link"].assert_not_called()
    for call in mocks["ensure_send"].call_args_list:
      self.assertEqual(call.args[3], mic)

  def test_master_on_empty_chain_uses_raw_mic(self):
    mocks = self.run_up(self.state([]), self.manifests())
    self.assert_raw_path(mocks)

  def test_master_on_all_bypassed_uses_raw_mic(self):
    mocks = self.run_up(self.state(self.chain(enabled=False)),
                        self.manifests())
    self.assert_raw_path(mocks)

  def test_master_on_all_unavailable_uses_raw_mic(self):
    mocks = self.run_up(self.state(self.chain()),
                        self.manifests(available=False))
    self.assert_raw_path(mocks)

  def test_master_on_missing_capture_node_uses_raw_mic(self):
    mocks = self.run_up(self.state(self.chain()), self.manifests(),
                        capture=None)
    self.assert_raw_path(mocks)

  def test_master_off_with_a_chain_uses_raw_mic(self):
    mocks = self.run_up(self.state(self.chain(), enabled=False),
                        self.manifests())
    self.assert_raw_path(mocks)

  def test_master_on_active_chain_routes_through_fx(self):
    mocks = self.run_up(self.state(self.chain()), self.manifests())
    mocks["set_mic_fx_link"].assert_called_once_with("alsa_in", True)
    mocks["set_mic_fx_playback_link"].assert_called_once_with()
    mocks["ensure_mic_bus_feed"].assert_not_called()
    for call in mocks["ensure_send"].call_args_list:
      self.assertEqual(call.args[3], wavemix.MIC_BUS + ".monitor")

  def test_master_on_chain_with_default_source_sentinel_uses_raw_mic(self):
    # A chain is loaded and live, but the saved input is still the unresolved
    # @DEFAULT_SOURCE@ sentinel (no concrete hardware port). Routing through FX
    # can never link it, so up() must fall back to the raw feed.
    state = self.state(self.chain())
    state["devices"]["input"] = "@DEFAULT_SOURCE@"
    mocks = self.run_up(state, self.manifests(), raw_outputs=())

    self.assert_raw_path(mocks, mic="@DEFAULT_SOURCE@")
    mocks["raw_mic_outputs"].assert_called_once_with("@DEFAULT_SOURCE@")

  def test_up_render_error_leaves_the_existing_graph_intact(self):
    state = self.state(self.chain())
    mocks = {name: Mock() for name in
             ("sanitize_devices", "unload_all", "ensure_buses",
              "ensure_defaults")}
    mocks["sanitize_devices"].return_value = False
    with patch.multiple(wavemix, **mocks), \
        patch.object(wavemix.fx, "discover_manifests", return_value={}), \
        patch.object(wavemix.fx, "render_to_disk",
                     side_effect=wavemix.fx.FxError("bad config")):
      with self.assertRaises(wavemix.fx.FxError):
        wavemix.up(state)

    mocks["unload_all"].assert_not_called()
    mocks["ensure_buses"].assert_not_called()


class MultiOutputGraphTests(unittest.TestCase):
  def hardware(self, *names):
    return [{"name": name, "properties": {"device.api": "alsa"}} for name in names]

  def stream(self, index, tag, sink):
    return {"index": index, "sink": sink,
            "volume": {"front-left": {"value_percent": "70%"}},
            "mute": False, "properties": {wavemix.TAG_KEY: tag}}

  def test_channel_targets_returns_each_selected_output(self):
    devices = {"output": "a", "outputs": ["a", "b", "c"]}
    self.assertEqual(wavemix.channel_targets({"source": "apps"}, "output", devices),
                     ["a", "b", "c"])
    self.assertEqual(wavemix.channel_targets({"source": "apps"}, "input", devices),
                     [wavemix.STREAM_BUS])

  def test_channel_targets_dedupes_and_falls_back(self):
    self.assertEqual(wavemix.channel_targets({}, "output", {"outputs": ["a", "a"]}), ["a"])
    self.assertEqual(wavemix.channel_targets({}, "output", {"output": "a"}), ["a"])
    self.assertEqual(wavemix.channel_targets({}, "output", {}), ["@DEFAULT_SINK@"])

  def test_ensure_send_creates_one_loopback_per_output(self):
    channel = {"id": "browser", "name": "Browser", "source": "apps"}
    devices = {"output": "a", "outputs": ["a", "b"], "input": "mic"}
    existing = [self.stream(3, "browser:output", 10)]
    with patch.object(wavemix, "sink_inputs", return_value=existing), \
         patch.object(wavemix, "sink_name_by_index", return_value={"10": "a"}), \
         patch.object(wavemix, "load_module") as load:
      wavemix.ensure_send(channel, "output", devices, "mic")

    load.assert_called_once()
    args = load.call_args.args
    self.assertEqual(args[0], "module-loopback")
    self.assertIn("sink=b", args)
    self.assertIn("sink_input_muted=1", args)
    self.assertIn(f"sink_input_properties={wavemix.TAG_KEY}=browser:output", args)
    self.assertIn("source=wavemix_browser.monitor", args)

  def test_graph_up_requires_a_stream_for_every_output_target(self):
    state = {
      "devices": {"output": "a", "outputs": ["a", "b"], "input": "mic"},
      "channels": [{
        "id": "browser", "name": "Browser", "source": "apps",
        "output": {"on": True, "volume": 70},
        "input": {"on": False, "volume": 50},
      }],
      "micFx": {"enabled": False},
    }
    inputs = [self.stream(1, wavemix.MICBUS_TAG, 99),
              self.stream(3, "browser:output", 10),
              self.stream(7, "browser:output", 11),
              self.stream(9, "browser:input", 20)]
    sinks = [{"index": 10, "name": "a"}, {"index": 11, "name": "b"},
             {"index": 20, "name": wavemix.STREAM_BUS}]
    with patch.object(wavemix, "existing_source_names",
                      return_value={wavemix.MIC_BUS_SOURCE,
                                    wavemix.STREAM_BUS_SOURCE}), \
         patch.object(wavemix, "existing_sink_names",
                      return_value={"wavemix_browser"}), \
         patch.object(wavemix, "sinks", return_value=sinks), \
         patch.object(wavemix, "sink_inputs", return_value=inputs):
      self.assertTrue(wavemix.graph_up(state))

    with patch.object(wavemix, "existing_source_names",
                      return_value={wavemix.MIC_BUS_SOURCE,
                                    wavemix.STREAM_BUS_SOURCE}), \
         patch.object(wavemix, "existing_sink_names",
                      return_value={"wavemix_browser"}), \
         patch.object(wavemix, "sinks", return_value=sinks), \
         patch.object(wavemix, "sink_inputs",
                      return_value=[si for si in inputs if si["sink"] != 11]):
      self.assertFalse(wavemix.graph_up(state))

  def test_graph_up_requires_raw_feed_when_the_chain_is_inactive(self):
    state = {"devices": {"output": "a", "outputs": ["a"], "input": "mic"},
             "channels": [],
             "micFx": {"enabled": True, "chain": []}}
    with patch.object(wavemix, "existing_source_names",
                      return_value={wavemix.MIC_BUS_SOURCE,
                                    wavemix.STREAM_BUS_SOURCE}), \
         patch.object(wavemix, "existing_sink_names", return_value=set()), \
         patch.object(wavemix, "sink_inputs", return_value=[]), \
         patch.object(wavemix, "_fx_manifests", return_value={}):
      self.assertFalse(wavemix.graph_up(state))

    feed = self.stream(1, wavemix.MICBUS_TAG, 99)
    with patch.object(wavemix, "existing_source_names",
                      return_value={wavemix.MIC_BUS_SOURCE,
                                    wavemix.STREAM_BUS_SOURCE}), \
         patch.object(wavemix, "existing_sink_names", return_value=set()), \
         patch.object(wavemix, "sink_inputs", return_value=[feed]), \
         patch.object(wavemix, "_fx_manifests", return_value={}):
      self.assertTrue(wavemix.graph_up(state))

  def test_graph_up_requires_fx_links_when_the_chain_is_active(self):
    state = {"devices": {"output": "a", "outputs": ["a"], "input": "mic"},
             "channels": [],
             "micFx": {"enabled": True, "chain": [{
               "id": "highpass-1", "plugin": "highpass",
               "enabled": True, "controls": {},
             }]}}
    manifests = {"highpass": {"available": True, "error": None}}
    for links, expected in ((False, False), (True, True)):
      with self.subTest(links=links), \
           patch.object(wavemix, "existing_source_names",
                        return_value={wavemix.MIC_BUS_SOURCE,
                                      wavemix.STREAM_BUS_SOURCE}), \
           patch.object(wavemix, "existing_sink_names", return_value=set()), \
           patch.object(wavemix, "sink_inputs", return_value=[]), \
           patch.object(wavemix, "_fx_manifests", return_value=manifests), \
           patch.object(wavemix.fx, "find_capture_node_id",
                        return_value=34), \
           patch.object(wavemix, "raw_mic_outputs",
                        return_value=["mic:capture_MONO"]), \
           patch.object(wavemix, "fx_links_present", return_value=links):
        self.assertIs(wavemix.graph_up(state), expected)

  def test_graph_up_default_source_sentinel_stays_stable_on_the_raw_feed(self):
    # Regression: with an unresolved @DEFAULT_SOURCE@ device and a loaded chain,
    # FX links can never exist, so graph_up() must treat the chain as inactive
    # and accept the raw mic-bus feed instead of asking the watcher to rebuild
    # the whole graph every two seconds.
    state = {"devices": {"output": "a", "outputs": ["a"],
                         "input": "@DEFAULT_SOURCE@"},
             "channels": [],
             "micFx": {"enabled": True, "chain": [{
               "id": "highpass-1", "plugin": "highpass",
               "enabled": True, "controls": {},
             }]}}
    manifests = {"highpass": {"available": True, "error": None}}
    feed = self.stream(1, wavemix.MICBUS_TAG, 99)
    links = Mock(return_value=False)
    with patch.object(wavemix, "existing_source_names",
                      return_value={wavemix.MIC_BUS_SOURCE,
                                    wavemix.STREAM_BUS_SOURCE}), \
         patch.object(wavemix, "existing_sink_names", return_value=set()), \
         patch.object(wavemix, "sink_inputs", return_value=[feed]), \
         patch.object(wavemix, "_fx_manifests", return_value=manifests), \
         patch.object(wavemix.fx, "find_capture_node_id", return_value=34), \
         patch.object(wavemix, "raw_mic_outputs", return_value=[]), \
         patch.object(wavemix, "fx_links_present", links):
      for _ in range(3):
        self.assertTrue(wavemix.graph_up(state))
    links.assert_not_called()

  def test_raw_mic_outputs_skips_sentinels_and_matches_concrete_ports(self):
    with patch.object(wavemix, "sh") as sh:
      self.assertEqual(wavemix.raw_mic_outputs("@DEFAULT_SOURCE@"), [])
    sh.assert_not_called()

    ports = "alsa_in:capture_MONO\nalsa_in:capture_FR\nother:output\n"
    with patch.object(wavemix, "sh", return_value=ports):
      self.assertEqual(wavemix.raw_mic_outputs("alsa_in"),
                       ["alsa_in:capture_MONO", "alsa_in:capture_FR"])
      self.assertEqual(wavemix.raw_mic_outputs("missing"), [])

  def test_fx_links_present_checks_capture_and_playback(self):
    text = (
      "wavemix_micfx.capture:input_MONO\n"
      "  |<- mic:capture_MONO\n"
      "wavemix_micfx:output_MONO\n"
      "  |-> wavemix_micbus:playback_FL\n"
      "  |-> wavemix_micbus:playback_FR\n"
    )
    outputs = "mic:capture_MONO\nwavemix_micfx:output_MONO\n"
    inputs = ("wavemix_micfx.capture:input_MONO\n"
              "wavemix_micbus:playback_FL\n"
              "wavemix_micbus:playback_FR\n")

    def fake_sh(*args):
      return {"-l": text, "-o": outputs, "-i": inputs}.get(args[-1], "")

    with patch.object(wavemix, "sh", side_effect=fake_sh):
      self.assertTrue(wavemix.fx_links_present("mic"))

    def missing_playback(*args):
      return {"-l": text.replace(
                  "  |-> wavemix_micbus:playback_FR\n", ""),
              "-o": outputs, "-i": inputs}.get(args[-1], "")

    with patch.object(wavemix, "sh", side_effect=missing_playback):
      self.assertFalse(wavemix.fx_links_present("mic"))

    def missing_capture(*args):
      return {"-l": text.replace("  |<- mic:capture_MONO\n", ""),
              "-o": outputs, "-i": inputs}.get(args[-1], "")

    with patch.object(wavemix, "sh", side_effect=missing_capture):
      self.assertFalse(wavemix.fx_links_present("mic"))

  def test_apply_all_sends_updates_every_copy(self):
    state = {"channels": [{
      "id": "browser", "source": "apps",
      "output": {"on": True, "volume": 70},
      "input": {"on": False, "volume": 50},
    }]}
    streams = [self.stream(3, "browser:output", 10),
               self.stream(7, "browser:output", 11)]
    calls = []

    def fake_sh(*args):
      calls.append(args)
      return ""

    with patch.object(wavemix, "sink_inputs", return_value=streams), \
         patch.object(wavemix, "sh", side_effect=fake_sh):
      wavemix.apply_all_sends(state)

    volumes = [call for call in calls if call[1] == "set-sink-input-volume"]
    mutes = [call for call in calls if call[1] == "set-sink-input-mute"]
    self.assertEqual({call[2] for call in volumes}, {"3", "7"})
    self.assertEqual({call[3] for call in volumes}, {"70%"})
    self.assertEqual({call[2] for call in mutes}, {"3", "7"})
    self.assertEqual({call[3] for call in mutes}, {"0"})

  def test_status_reports_output_targets_and_all_target_liveness(self):
    state = {
      "devices": {"output": "a", "outputs": ["a", "b"], "input": "mic"},
      "channels": [{
        "id": "browser", "name": "Browser", "source": "apps",
        "output": {"on": True, "volume": 70},
        "input": {"on": False, "volume": 50},
      }],
      "micFx": {"enabled": False},
    }
    streams = [self.stream(3, "browser:output", 10),
               self.stream(7, "browser:output", 11)]
    output = io.StringIO()
    with patch.object(wavemix, "sink_inputs", return_value=streams), \
         patch.object(wavemix, "sink_name_by_index",
                      return_value={"10": "a", "11": "b"}), \
         patch.object(wavemix, "sinks", return_value=self.hardware("a", "b")), \
         patch.object(wavemix, "sources", return_value=[]), \
         patch.object(wavemix, "existing_source_names", return_value=set()), \
         patch.object(wavemix, "sh", return_value="a"), \
         contextlib.redirect_stdout(output):
      wavemix.status(state, True)

    send = json.loads(output.getvalue())["graph"]["channels"]["browser"]["sends"]["output"]
    self.assertEqual(send["targets"], ["a", "b"])
    self.assertEqual(send["liveTargets"], ["a", "b"])
    self.assertTrue(send["live"])
    self.assertEqual(send["liveVolume"], 70)
    self.assertFalse(send["liveMuted"])

  def test_status_is_not_live_until_every_target_has_a_stream(self):
    state = {
      "devices": {"output": "a", "outputs": ["a", "b"], "input": "mic"},
      "channels": [{
        "id": "browser", "name": "Browser", "source": "apps",
        "output": {"on": True, "volume": 70},
        "input": {"on": False, "volume": 50},
      }],
      "micFx": {"enabled": False},
    }
    output = io.StringIO()
    with patch.object(wavemix, "sink_inputs",
                      return_value=[self.stream(3, "browser:output", 10)]), \
         patch.object(wavemix, "sink_name_by_index", return_value={"10": "a"}), \
         patch.object(wavemix, "sinks", return_value=self.hardware("a", "b")), \
         patch.object(wavemix, "sources", return_value=[]), \
         patch.object(wavemix, "existing_source_names", return_value=set()), \
         patch.object(wavemix, "sh", return_value="a"), \
         contextlib.redirect_stdout(output):
      wavemix.status(state, True)

    send = json.loads(output.getvalue())["graph"]["channels"]["browser"]["sends"]["output"]
    self.assertEqual(send["liveTargets"], ["a"])
    self.assertFalse(send["live"])

  def test_sanitize_devices_keeps_at_least_one_output(self):
    state = {
      "devices": {"output": "wavemix_browser",
                  "outputs": ["wavemix_browser", "speakers"], "input": "mic"},
    }
    with patch.object(wavemix, "sinks", return_value=self.hardware("speakers")), \
         patch.object(wavemix, "sources", return_value=self.hardware("mic")), \
         patch.object(wavemix, "default_name", return_value="speakers"):
      changed = wavemix.sanitize_devices(state)

    self.assertTrue(changed)
    self.assertEqual(state["devices"]["outputs"], ["speakers"])
    self.assertEqual(state["devices"]["output"], "speakers")

  def test_sanitize_devices_falls_back_to_the_default_sink(self):
    state = {
      "devices": {"output": "wavemix_browser",
                  "outputs": ["wavemix_browser"], "input": "mic"},
    }
    with patch.object(wavemix, "sinks", return_value=self.hardware("speakers")), \
         patch.object(wavemix, "sources", return_value=self.hardware("mic")), \
         patch.object(wavemix, "default_name", return_value="speakers"):
      changed = wavemix.sanitize_devices(state)

    self.assertTrue(changed)
    self.assertEqual(state["devices"]["outputs"], ["speakers"])
    self.assertEqual(state["devices"]["output"], "speakers")

  def test_device_mute_is_true_only_when_all_outputs_are_muted(self):
    state = {"devices": {"output": "a", "outputs": ["a", "b"], "input": "mic"}}
    devices = [{"name": "a", "mute": True}, {"name": "b", "mute": False}]
    with patch.object(wavemix, "sinks", return_value=devices):
      self.assertFalse(wavemix.device_mute("output", state))

    devices[1]["mute"] = True
    with patch.object(wavemix, "sinks", return_value=devices):
      self.assertTrue(wavemix.device_mute("output", state))


class MultiOutputCliTests(unittest.TestCase):
  def setUp(self):
    self.state = {
      "version": 2,
      "devices": {"output": "a", "outputs": ["a"], "input": "mic"},
      "channels": [], "rules": {}, "defaults": {},
      "micFx": {"enabled": False, "chain": []},
    }
    load = patch.object(wavemix, "load_state",
                        side_effect=lambda: self.state)
    lock = patch.object(wavemix, "graph_lock", contextlib.nullcontext)
    for patcher in (load, lock):
      patcher.start()
      self.addCleanup(patcher.stop)
    self.save_state = patch.object(wavemix, "save_state")
    self.save_mock = self.save_state.start()
    self.addCleanup(self.save_state.stop)
    self.up = patch.object(wavemix, "up")
    self.up_mock = self.up.start()
    self.addCleanup(self.up.stop)

  def run_cli(self, *argv):
    with contextlib.redirect_stdout(io.StringIO()):
      return wavemix.main(list(argv))

  def test_output_add_appends_and_rebuilds(self):
    self.assertEqual(self.run_cli("device", "output-add", "b"), 0)

    self.assertEqual(self.state["devices"]["outputs"], ["a", "b"])
    self.assertEqual(self.state["devices"]["output"], "a")
    self.save_mock.assert_called_once_with(self.state)
    self.up_mock.assert_called_once_with(self.state)

  def test_output_add_rejects_duplicates_and_virtual_devices(self):
    for name in ("a", "wavemix_browser"):
      with self.subTest(name=name):
        with contextlib.redirect_stderr(io.StringIO()), \
             self.assertRaises(SystemExit) as raised:
          wavemix.main(["device", "output-add", name])
        self.assertNotEqual(raised.exception.code, 0)
        self.assertEqual(self.state["devices"]["outputs"], ["a"])
        self.save_mock.assert_not_called()
        self.up_mock.assert_not_called()

  def test_output_remove_refuses_the_last_output(self):
    with contextlib.redirect_stderr(io.StringIO()), \
         self.assertRaises(SystemExit) as raised:
      wavemix.main(["device", "output-remove", "a"])

    self.assertNotEqual(raised.exception.code, 0)
    self.assertEqual(self.state["devices"]["outputs"], ["a"])
    self.assertEqual(self.state["devices"]["output"], "a")
    self.save_mock.assert_not_called()
    self.up_mock.assert_not_called()

  def test_output_remove_keeps_the_primary(self):
    self.state["devices"].update({"output": "a", "outputs": ["a", "b"]})

    self.assertEqual(self.run_cli("device", "output-remove", "b"), 0)

    self.assertEqual(self.state["devices"]["outputs"], ["a"])
    self.assertEqual(self.state["devices"]["output"], "a")
    self.up_mock.assert_called_once_with(self.state)

  def test_output_remove_promotes_the_next_output(self):
    self.state["devices"].update({"output": "a", "outputs": ["a", "b", "c"]})

    self.assertEqual(self.run_cli("device", "output-remove", "a"), 0)

    self.assertEqual(self.state["devices"]["outputs"], ["b", "c"])
    self.assertEqual(self.state["devices"]["output"], "b")
    self.up_mock.assert_called_once_with(self.state)

  def test_output_moves_the_name_to_the_front_and_keeps_others(self):
    self.state["devices"].update({"output": "a", "outputs": ["a", "b", "c"]})

    self.assertEqual(self.run_cli("device", "output", "b"), 0)

    self.assertEqual(self.state["devices"]["outputs"], ["b", "a", "c"])
    self.assertEqual(self.state["devices"]["output"], "b")
    self.up_mock.assert_called_once_with(self.state)

  def test_device_input_stays_a_single_device(self):
    self.assertEqual(self.run_cli("device", "input", "mic2"), 0)

    self.assertEqual(self.state["devices"]["input"], "mic2")
    self.assertEqual(self.state["devices"]["outputs"], ["a"])
    self.assertEqual(self.state["devices"]["output"], "a")
    self.up_mock.assert_called_once_with(self.state)

  def test_devices_json_includes_selected_outputs(self):
    self.state["devices"].update({"output": "a", "outputs": ["a", "b"]})

    def hardware(which):
      if which == "output":
        return [{"name": "a", "description": "A"},
                {"name": "b", "description": "B"}]
      return [{"name": "mic", "description": "Mic"}]

    output = io.StringIO()
    with patch.object(wavemix, "hardware_devices", side_effect=hardware), \
         patch.object(wavemix, "sh", return_value=""), \
         contextlib.redirect_stdout(output):
      self.assertEqual(wavemix.main(["devices", "--json"]), 0)

    selected = json.loads(output.getvalue())["selected"]
    self.assertEqual(selected["outputs"], ["a", "b"])
    self.assertEqual(selected["output"], "a")

  def test_mute_toggle_applies_to_every_output(self):
    self.state["devices"]["outputs"] = ["a", "b"]
    devices = [{"name": "a", "mute": False}, {"name": "b", "mute": True}]
    calls = []

    def fake_sh(*args):
      calls.append(args)
      return ""

    with patch.object(wavemix, "sinks", return_value=devices), \
         patch.object(wavemix, "sh", side_effect=fake_sh), \
         contextlib.redirect_stdout(io.StringIO()):
      self.assertEqual(wavemix.main(["mute", "output", "toggle"]), 0)

    applied = [call for call in calls if call[1] == "set-sink-mute"]
    self.assertEqual({call[2] for call in applied}, {"a", "b"})
    self.assertEqual({call[3] for call in applied}, {"1"})

  def test_mute_on_and_off_apply_to_every_output(self):
    self.state["devices"]["outputs"] = ["a", "b"]
    for action, value in (("on", "1"), ("off", "0")):
      with self.subTest(action=action):
        calls = []

        def fake_sh(*args):
          calls.append(args)
          return ""

        with patch.object(wavemix, "sinks", return_value=[]), \
             patch.object(wavemix, "sh", side_effect=fake_sh), \
             contextlib.redirect_stdout(io.StringIO()):
          self.assertEqual(
            wavemix.main(["mute", "output", action]), 0)

        applied = [call for call in calls if call[1] == "set-sink-mute"]
        self.assertEqual({call[2] for call in applied}, {"a", "b"})
        self.assertEqual({call[3] for call in applied}, {value})

  def test_input_mute_stays_single_device(self):
    calls = []

    def fake_sh(*args):
      calls.append(args)
      return ""

    with patch.object(wavemix, "sources",
                      return_value=[{"name": "mic", "mute": False}]), \
         patch.object(wavemix, "sh", side_effect=fake_sh), \
         contextlib.redirect_stdout(io.StringIO()):
      self.assertEqual(wavemix.main(["mute", "input", "on"]), 0)

    applied = [call for call in calls if call[1].startswith("set-")]
    self.assertEqual(applied, [("pactl", "set-source-mute", "mic", "1")])

  def test_mutes_reports_output_true_only_when_all_are_muted(self):
    for mutes, expected in (((False, True), False), ((True, True), True)):
      with self.subTest(mutes=mutes):
        devices = [{"name": "a", "mute": mutes[0]},
                   {"name": "b", "mute": mutes[1]}]
        self.state["devices"]["outputs"] = ["a", "b"]
        output = io.StringIO()
        with patch.object(wavemix, "sinks", return_value=devices), \
             patch.object(wavemix, "sources", return_value=[]), \
             contextlib.redirect_stdout(output):
          self.assertEqual(wavemix.main(["mutes"]), 0)

        self.assertIs(json.loads(output.getvalue())["output"], expected)


class InstallerTests(unittest.TestCase):
  def test_installer_ships_effect_module_and_manifests(self):
    text = (ROOT / "install.sh").read_text()
    self.assertIn("wavemix_fx.py", text)
    self.assertIn("plugins", text)
    self.assertIn("fx render", text)
    self.assertIn("fx apply", text)


if __name__ == "__main__":
  unittest.main()
