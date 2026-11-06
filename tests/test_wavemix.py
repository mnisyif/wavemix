import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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
      self.assertTrue(manifest["available"] or manifest["error"])
    self.assertTrue(manifests["rnnoise"]["default"])
    self.assertEqual(
      {control["key"] for control in manifests["rnnoise"]["controls"]},
      {"vadThreshold", "vadGrace", "retroactiveGrace", "dryMix"})
    self.assertEqual(manifests["highpass"]["label"], "bq_highpass")

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
      "source", "available", "gpu", "requires", "error"})


PW_CLI_PROPS = """
Object: size 288, type Spa:Pod:Object:Param:Props (262146), id Spa:Enum:ParamId:Props (2)
  Prop: key Spa:Pod:Object:Param:Props:params (524289), flags 00000000
    Struct: size 264
      String "rnnoise:VAD Threshold (%)"
      Int 50
      String "rnnoise:VAD Grace Period (ms)"
      Int 200
      String "rnnoise:Retroactive VAD Grace (ms)"
      Int 0
      String "rnnoise:Placeholder"
      Float 170141173319264429905852091742258462720.000000
      String "rnnoise:Dry Mix"
      Float 0.000000
"""


def control(key):
  return next(spec for spec in wavemix.MICFX_CONTROLS if spec["key"] == key)


class ParseTests(unittest.TestCase):
  def test_reads_integer_and_float_controls(self):
    values = wavemix.parse_micfx_params(PW_CLI_PROPS)

    self.assertEqual(values["VAD Threshold (%)"], 50)
    self.assertEqual(values["VAD Grace Period (ms)"], 200)
    self.assertEqual(values["Retroactive VAD Grace (ms)"], 0)
    self.assertEqual(values["Dry Mix"], 0.0)
    self.assertIsInstance(values["Dry Mix"], float)

  def test_ignores_unrelated_properties(self):
    text = PW_CLI_PROPS + '\n      String "channelmix.normalize"\n      Bool false\n'
    values = wavemix.parse_micfx_params(text)

    self.assertNotIn("channelmix.normalize", values)

  def test_returns_empty_for_empty_input(self):
    self.assertEqual(wavemix.parse_micfx_params(""), {})


class ControlTests(unittest.TestCase):
  def test_control_keys_are_unique_and_ranges_make_sense(self):
    keys = [spec["key"] for spec in wavemix.MICFX_CONTROLS]
    params = [spec["param"] for spec in wavemix.MICFX_CONTROLS]

    self.assertEqual(len(keys), len(set(keys)))
    self.assertEqual(len(params), len(set(params)))
    self.assertEqual(set(keys), {"vadThreshold", "vadGrace", "retroactiveGrace", "dryMix"})
    for spec in wavemix.MICFX_CONTROLS:
      self.assertLessEqual(spec["min"], spec["max"])
      self.assertGreater(spec["step"], 0)
      self.assertGreater(spec["scale"], 0)

  def test_dry_mix_scales_between_percent_and_raw_fraction(self):
    spec = control("dryMix")

    self.assertEqual(wavemix.micfx_raw_value(spec, 50), 0.5)
    self.assertEqual(wavemix.micfx_raw_value(spec, 100), 1.0)
    self.assertEqual(wavemix.micfx_display_value(spec, 0.25), 25)
    self.assertEqual(wavemix.micfx_display_value(spec, 1.0), 100)

  def test_integer_controls_keep_their_display_value(self):
    spec = control("vadThreshold")

    self.assertEqual(wavemix.micfx_raw_value(spec, 60), 60)
    self.assertEqual(wavemix.micfx_display_value(spec, 60), 60)


class SnapshotTests(unittest.TestCase):
  @patch.object(wavemix, "sh", return_value=PW_CLI_PROPS)
  @patch.object(wavemix, "micfx_node_id", return_value=34)
  def test_reads_live_values_and_metadata(self, _node, _sh):
    snapshot = wavemix.micfx_controls_snapshot()
    by_key = {item["key"]: item for item in snapshot["controls"]}

    self.assertTrue(snapshot["running"])
    self.assertEqual(by_key["vadThreshold"]["value"], 50)
    self.assertEqual(by_key["vadThreshold"]["max"], 99)
    self.assertEqual(by_key["vadGrace"]["value"], 200)
    self.assertEqual(by_key["retroactiveGrace"]["value"], 0)
    self.assertEqual(by_key["dryMix"]["value"], 0)
    self.assertEqual(by_key["dryMix"]["unit"], "%")

  @patch.object(wavemix, "micfx_node_id", return_value=None)
  def test_falls_back_to_defaults_when_node_is_missing(self, _node):
    snapshot = wavemix.micfx_controls_snapshot()
    by_key = {item["key"]: item for item in snapshot["controls"]}

    self.assertFalse(snapshot["running"])
    self.assertEqual(by_key["vadThreshold"]["value"], 50)
    self.assertEqual(by_key["vadGrace"]["value"], 200)
    self.assertEqual(by_key["retroactiveGrace"]["value"], 0)
    self.assertEqual(by_key["dryMix"]["value"], 0)


class SetControlTests(unittest.TestCase):
  @patch.object(wavemix, "sh")
  @patch.object(wavemix, "micfx_node_id", return_value=34)
  def test_stores_display_value_and_sends_raw_value(self, _node, sh):
    state = {"micFx": {"enabled": True}}

    result = wavemix.set_micfx_control(state, "dryMix", 25)

    self.assertEqual(state["micFx"]["controls"]["dryMix"], 25)
    self.assertTrue(result["applied"])
    self.assertEqual(sh.call_args.args[:4], ("pw-cli", "set-param", "34", "Props"))
    self.assertIn('"rnnoise:Dry Mix" 0.250000', sh.call_args.args[4])

  @patch.object(wavemix, "sh")
  @patch.object(wavemix, "micfx_node_id", return_value=34)
  def test_clamps_values_to_the_control_range(self, _node, sh):
    state = {"micFx": {"enabled": True}}

    wavemix.set_micfx_control(state, "vadThreshold", 500)
    self.assertEqual(state["micFx"]["controls"]["vadThreshold"], 99)

    wavemix.set_micfx_control(state, "vadThreshold", -10)
    self.assertEqual(state["micFx"]["controls"]["vadThreshold"], 0)

    self.assertIn('"rnnoise:VAD Threshold (%)" 99', sh.call_args_list[0].args[4])
    self.assertIn('"rnnoise:VAD Threshold (%)" 0', sh.call_args_list[1].args[4])

  def test_rejects_unknown_control_without_touching_state(self):
    state = {"micFx": {"enabled": True}}

    result = wavemix.set_micfx_control(state, "nope", 1)

    self.assertIsNone(result)
    self.assertNotIn("controls", state["micFx"])

  @patch.object(wavemix, "sh")
  @patch.object(wavemix, "micfx_node_id", return_value=None)
  def test_still_stores_when_the_node_is_not_running(self, _node, sh):
    state = {"micFx": {"enabled": True}}

    result = wavemix.set_micfx_control(state, "vadGrace", 500)

    self.assertEqual(state["micFx"]["controls"]["vadGrace"], 500)
    self.assertFalse(result["applied"])
    sh.assert_not_called()


class ApplyOverridesTests(unittest.TestCase):
  @patch.object(wavemix, "sh")
  @patch.object(wavemix, "micfx_node_id", return_value=34)
  def test_applies_only_stored_overrides(self, _node, sh):
    state = {"micFx": {"controls": {"vadGrace": 300, "dryMix": 25}}}

    wavemix.apply_micfx_overrides(state)

    self.assertEqual(sh.call_count, 2)
    payloads = [call.args[4] for call in sh.call_args_list]
    self.assertTrue(any('"rnnoise:VAD Grace Period (ms)" 300' in p for p in payloads))
    self.assertTrue(any('"rnnoise:Dry Mix" 0.250000' in p for p in payloads))

  @patch.object(wavemix, "sh")
  @patch.object(wavemix, "micfx_node_id", return_value=None)
  def test_does_nothing_when_the_node_is_missing(self, _node, sh):
    state = {"micFx": {"controls": {"vadGrace": 300}}}

    wavemix.apply_micfx_overrides(state)

    sh.assert_not_called()

  @patch.object(wavemix, "sh")
  @patch.object(wavemix, "micfx_node_id", return_value=34)
  def test_ignores_unknown_stored_keys(self, _node, sh):
    state = {"micFx": {"controls": {"gone": 10}}}

    wavemix.apply_micfx_overrides(state)

    sh.assert_not_called()


if __name__ == "__main__":
  unittest.main()
