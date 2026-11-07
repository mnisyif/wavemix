# Wavemix Effects Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real floating Effects window and atomic chain editing for Wavemix's native/GPU effect chain.

**Architecture:** A new `mnisyif.wavemix-fx` panel plugin hosts a Quickshell `FloatingWindow`. The existing bar widget opens it. A new `wavemix fx commit --stdin` command validates the whole edited chain, writes `state.json`, renders once, and restarts audio once. The chain model reserves `host`/`format` fields for the later Carla VST3/CLAP backend.

**Tech Stack:** Python 3, `unittest`, PipeWire filter-chain, Quickshell/QML, Omarchy shell plugin API.

**Spec:** `docs/superpowers/specs/2026-11-07-wavemix-effects-window-design.md`

## Global Constraints

- Target version: `1.2.0`.
- `state.json` stays version 2; `micFx.chain` keeps its current shape.
- Phase 1 only: no VST3/CLAP discovery or hosting. That is Phase 2 (Carla + OSC).
- The chain is linear. No parallel or branching graphs.
- GPU is metadata only (`gpu: true`); never a separate host path.
- Structural Apply performs exactly one render and one audio restart.
- Live control edits use `fx set` and do not mark the structural draft dirty.
- Keep every existing test green.
- Never edit `/usr/share/omarchy/`; only the repo and `~/.config`/`~/.local`.

## Review Focus

- A new effect with edited controls must keep those controls after Apply.
- Reordering must not drop, duplicate, or reassign an existing instance.
- A render failure must leave `state.json` and live audio unchanged.
- A restart failure must report `restarted: false` without losing the new state.
- Closing or hiding the window with a dirty draft must not silently discard it.
- Live knob edits must not dirty the structural draft or trigger a restart.
- A watcher reconcile must not interleave with a commit (`graph_lock`).

---

### Task 1: Extend plugin metadata for the window

**Files:**
- Modify: `bin/wavemix_fx.py`
- Test: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: `plugin_list(manifests: dict[str, dict]) -> list[dict]`
- Produces: each plugin row also carries `type: str`, `gpu: bool`, and
  `controls: list[dict]`. Each control dict has `key`, `label`, `param`,
  `default`, `min`, `max`, `step`, `unit`, `integer`, `raw_float`, `scale`.

- [ ] **Step 1: Write the failing test**

Add to `ManifestTests`:

```python
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 -m unittest tests.test_wavemix.ManifestTests.test_plugin_list_includes_type_gpu_and_control_defaults -v`
Expected: FAIL with `KeyError: 'type'`.

- [ ] **Step 3: Implement the metadata change**

In `bin/wavemix_fx.py`:

- Add `"type"` and `"allowMultiple"` to `_PLUGIN_LIST_FIELDS`.
- Add `"type": manifest.get("type") if manifest else None` to
  `_instance_snapshot`, so `fx state --json` chain entries carry the format.
- In `plugin_list`, build each row from the manifest fields and add:

```python
row["controls"] = [
  {key: control.get(key) for key in (
    "key", "label", "param", "default", "min", "max", "step", "unit",
    "integer", "raw_float", "scale")}
  for control in manifest.get("controls", [])
  if isinstance(control, dict)
]
```

Keep the existing sort by `(id, source)`.

Also update `CliFxTests.test_fx_state_json_contains_versions_and_chain` to
assert `entry["type"] == "ladspa"`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest tests.test_wavemix.ManifestTests tests.test_wavemix.CliFxTests.test_fx_state_json_contains_versions_and_chain -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix_fx.py tests/test_wavemix.py
git commit -m "feat(fx): expose plugin type, gpu, and control defaults"
```

---

### Task 2: Add atomic chain replacement

**Files:**
- Modify: `bin/wavemix_fx.py`
- Test: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: `_new_instance(plugin_id, instance_id, manifest) -> dict`,
  `_clamp_display(spec, value)`, `find_instance(state, instance_id)`.
- Produces:
  - `_next_instance_id(chain: list, plugin_id: str) -> str`
  - `replace_chain(state: dict, manifests: dict[str, dict], entries: list[dict]) -> list[dict]`
  - `replace_chain` mutates `state["micFx"]["chain"]` and returns the new
    chain. It raises `FxError` for invalid input. Callers pass a deep copy.

- [ ] **Step 1: Write the failing tests**

Add a new `ChainReplaceTests` class with its own manifests setup, or reuse
`StateTests.manifests`. Use `rnnoise` and `highpass` as available plugins.

```python
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `python3 -m unittest tests.test_wavemix.ChainReplaceTests -v`
Expected: FAIL with `AttributeError: module 'wavemix_fx' has no attribute 'replace_chain'`.

- [ ] **Step 3: Implement `_next_instance_id` and `replace_chain`**

Refactor `add_instance` so both functions share:

```python
def _next_instance_id(chain: list, plugin_id: str) -> str:
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
  return f"{plugin_id}-{number}"
```

`replace_chain` must:

- Reject a non-list `entries` or non-dict entries.
- Reject duplicate `instance` ids.
- For an existing `instance`:
  - reject if it is not in the current chain;
  - reject if `plugin` differs from the stored plugin;
  - deep-copy the stored entry so unknown fields and controls survive;
  - set `enabled` from the entry, default `true`;
  - ignore incoming controls (live `fx set` already stored them).
- For a new entry (`instance` empty):
  - require a known, available manifest;
  - enforce `allowMultiple`;
  - generate the id with `_next_instance_id` against the candidate chain;
  - create `_new_instance`, set `enabled`, and apply provided `controls`
    through `_clamp_display` against the manifest control specs.
- At the end, assign `state["micFx"]["chain"] = new_chain` and return it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest tests.test_wavemix.ChainReplaceTests tests.test_wavemix.StateTests -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix_fx.py tests/test_wavemix.py
git commit -m "feat(fx): add atomic chain replacement"
```

---

### Task 3: Add `wavemix fx commit --stdin`

**Files:**
- Modify: `bin/wavemix`
- Test: `tests/test_wavemix.py`

**Interfaces:**
- Consumes: `fx.replace_chain`, `fx.render_to_disk`, `save_state`,
  `graph_lock`, `restart_audio`, `_fx_manifests`.
- Produces: `wavemix fx commit --stdin [--json]`.
  - Reads one line of JSON from stdin.
  - Success JSON: `{"ok": true, "restarted": bool, "chain": [...]}`.
  - Handled error JSON: `{"ok": false, "error": "..."}` and exit 1.

- [ ] **Step 1: Write the failing CLI tests**

Add to `CliFxTests`:

```python
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `python3 -m unittest tests.test_wavemix.CliFxTests.test_fx_commit_replaces_chain_and_restarts_once -v`
Expected: FAIL because `commit` is not a valid `fx` action.

- [ ] **Step 3: Implement the command**

In `bin/wavemix`:

- Add `import copy`.
- Add `"commit"` to the `fx` action choices.
- Add `p.add_argument("--stdin", action="store_true", help="read the chain as one JSON line from stdin")`.
- Add `_cmd_fx_commit(args, state, manifests)`:

```python
def _cmd_fx_commit(args, state: dict, manifests: dict[str, dict]) -> None:
  if not getattr(args, "stdin", False):
    raise fx.FxError("fx commit needs --stdin")
  try:
    payload = json.loads(sys.stdin.readline())
  except (json.JSONDecodeError, TypeError, ValueError):
    raise fx.FxError("fx commit received invalid JSON") from None
  if not isinstance(payload, dict) or not isinstance(payload.get("chain"), list):
    raise fx.FxError('fx commit payload must be {"chain": [...]}')

  candidate = copy.deepcopy(state)
  chain = fx.replace_chain(candidate, manifests, payload["chain"])
  with graph_lock():
    fx.render_to_disk(candidate, manifests, fx.WAVEMIX_VERSION)
    save_state(candidate)
    restarted = restart_audio()

  result = {
    "ok": True,
    "restarted": bool(restarted),
    "chain": [
      {"instance": item.get("id"), "plugin": item.get("plugin"),
       "enabled": bool(item.get("enabled", True))}
      for item in chain if isinstance(item, dict)
    ],
  }
  if getattr(args, "json", False):
    print(json.dumps(result))
  else:
    print("wavemix: effect chain applied" if restarted
          else "wavemix: effect chain saved; audio restart failed")
```

- Handle `FxError` inside `_cmd_fx_commit` so `--json` emits the error object
  and the command returns a non-zero code without raising `SystemExit`:

```python
  try:
    ...
  except fx.FxError as exc:
    if getattr(args, "json", False):
      print(json.dumps({"ok": False, "error": str(exc)}))
      return 1
    raise
```

- Dispatch it in `cmd_fx` with `elif action == "commit": return _cmd_fx_commit(...)`.
- Make `cmd_fx` return the result of `_cmd_fx_commit`; other actions still
  return `None`.
- Change `main` to propagate an integer result:

```python
  try:
    return int(args.func(args) or 0)
  except fx.FxError as exc:
    print(f"wavemix: {exc}", file=sys.stderr)
    return 1
```

This keeps the existing tests that call `wavemix.main(...)` and compare the
return code working.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest tests.test_wavemix.CliFxTests -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/wavemix tests/test_wavemix.py
git commit -m "feat(fx): add atomic chain commit command"
```

---

### Task 4: Scaffold the floating-window plugin

**Files:**
- Create: `fx-plugin/manifest.json`
- Create: `fx-plugin/FxWindow.qml`
- Modify: `install.sh`

**Interfaces:**
- Consumes: Omarchy shell panel contract (`open(payloadJson)`, `close()`,
  `opened`, `shell`, `manifest`).
- Produces: plugin id `mnisyif.wavemix-fx`, entry point `FxWindow.qml`.

- [ ] **Step 1: Create the manifest**

`fx-plugin/manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "mnisyif.wavemix-fx",
  "name": "Wavemix Effects",
  "version": "1.2.0",
  "author": "mnisyif",
  "description": "Edit the Wavemix microphone effect chain",
  "kinds": ["panel"],
  "keepLoaded": true,
  "entryPoints": { "panel": "FxWindow.qml" }
}
```

- [ ] **Step 2: Create a minimal window**

`fx-plugin/FxWindow.qml` starts as an `Item` with:

- `property var shell: null`, `property var manifest: null`
- `property bool opened: window.visible`
- `function open(payloadJson) { window.visible = true }`
- `function close() { window.visible = false }`
- a `FloatingWindow` with title `Wavemix — Effects`, `color:
  Color.background`, `implicitWidth: 820`, `implicitHeight: 700`,
  `minimumSize: Qt.size(700, 540)`.
- a `Text` child saying `Wavemix Effects` so the window is visible during
  scaffolding.

Import `QtQuick`, `Quickshell`, `qs.Commons`, `qs.Ui`.

- [ ] **Step 3: Update `install.sh`**

Add:

```bash
fx_plugin_dir="$config_home/omarchy/plugins/mnisyif.wavemix-fx"
install -d "$fx_plugin_dir"
install -m 0644 "$repo/fx-plugin/manifest.json" "$fx_plugin_dir/manifest.json"
install -m 0644 "$repo/fx-plugin/FxWindow.qml" "$fx_plugin_dir/FxWindow.qml"
```

After the existing rescan, add:

```bash
omarchy plugin enable mnisyif.wavemix-fx >/dev/null 2>&1 || true
```

- [ ] **Step 4: Install and verify the scaffold**

Run: `./install.sh`
Expected: install completes; `omarchy plugin list --json` contains
`mnisyif.wavemix-fx`.

Run: `omarchy-shell shell summon mnisyif.wavemix-fx '{}'`
Expected: the floating window appears with `Wavemix Effects`.

Run: `omarchy-shell shell hide mnisyif.wavemix-fx`
Expected: the window disappears.

Run: `qmllint fx-plugin/FxWindow.qml`
Expected: no syntax errors.

- [ ] **Step 5: Commit**

```bash
git add fx-plugin install.sh
git commit -m "feat(plugin): scaffold floating effects window"
```

---

### Task 5: Build the chain view and live settings

**Files:**
- Modify: `fx-plugin/FxWindow.qml`

**Interfaces:**
- Consumes: `wavemix fx state --json`, `wavemix fx set <instance> <key>
  <value>`, the plugin rows from Task 1.
- Produces: `serverState`, `serverChain`, `plugins`, `selectedInstance`,
  `selectEffect(instance)`, `setControl(instance, key, value, control)`.

- [ ] **Step 1: Add the state process**

Add a `Process` for `wavemix fx state --json` with stdout parsed into
`serverState`. On `open()`, start it. On failure, show a load-error text and a
Retry action.

- [ ] **Step 2: Add the chain list and settings**

Implement the two-column layout from the spec:

- Left: a `Column`/`Flickable` of `FxChainRow` delegates built from
  `serverChain`. Show order number, name, instance id, status, bypass, and
  remove. Selecting a row sets `selectedInstance`.
- Right: `FxSettings` for the selected entry. Port `FxChainRow`, `FxSettings`,
  `FxControlRow`, and `FxPluginRow` from `plugin/Panel.qml` (currently around
  lines 1559–1990) into `fx-plugin/FxWindow.qml`, adapting `root.fx*`
  references to the window's own properties.
- Controls read values from the selected `serverChain` entry. On slider
  release, call `setControl`, which runs `fx set` and refreshes state after the
  command exits.

- [ ] **Step 3: Verify the chain view**

Run: `omarchy-shell shell summon mnisyif.wavemix-fx '{}'`
Expected: the current RNNoise chain appears with its instance id and controls.

Move the VAD threshold slider.
Expected: `wavemix fx state --json` shows the new value; audio updates live;
no PipeWire restart is logged.

Run: `qmllint fx-plugin/FxWindow.qml`
Expected: no syntax errors.

- [ ] **Step 4: Commit**

```bash
git add fx-plugin/FxWindow.qml
git commit -m "feat(plugin): show effect chain and live controls"
```

---

### Task 6: Add staged editing, drag reorder, and Apply

**Files:**
- Modify: `fx-plugin/FxWindow.qml`

**Interfaces:**
- Consumes: `wavemix fx commit --stdin --json`, `wavemix fx plugins --json`
  (via `fx state`), and the plugin metadata from Task 1.
- Produces:
  - `draft: list`, `dirty: bool`, `addDraft(pluginId)`,
    `removeDraft(key)`, `toggleDraft(key)`, `moveDraft(from, to)`,
    `applyDraft()`, `discardDraft()`.
  - A commit `Process` with `stdinEnabled: true`.

- [ ] **Step 1: Add the draft model**

- Copy `serverChain` into `draft` when state loads and when not dirty.
- Each draft entry: `{ key, instance, plugin, enabled, isNew, controls }`.
- Existing entries use `instance` as `key`; new entries use `new:<n>`.
- `dirty` compares `[plugin, instance, enabled]` order against the loaded
  server signature. Controls do not participate.

- [ ] **Step 2: Add add/remove/bypass**

- `+ Add effect` swaps the left column to `FxPluginRow` list with Back.
- Only `available` plugins can be added. Unavailable rows show their
  `requires`/`error` and are disabled.
- `addDraft` appends an entry with default controls from the plugin metadata.
- Bypass toggles `draft[i].enabled`; remove deletes the entry.
- New entries' controls edit `draft[i].controls`; existing entries' controls
  continue to use `fx set`.
- Disable controls for draft-bypassed entries with
  `Bypassed — apply to change`.

- [ ] **Step 3: Add drag reorder**

Use the row's drag handle:

- On press, record the source index and pointer y.
- On move, compute the target index from the row midpoints and show an
  insertion line/ghost.
- On release, call `moveDraft(from, to)`.
- Do not call the CLI during the drag.

- [ ] **Step 4: Add Apply/Discard and error handling**

- Apply serializes:
  ```json
  {"chain": [
    {"instance": "rnnoise-1", "plugin": "rnnoise", "enabled": true},
    {"instance": "", "plugin": "highpass", "enabled": true,
     "controls": {"freq": 80}}
  ]}
  ```
  and writes it to the commit process's stdin with a trailing newline.
- While applying, disable structural controls and show
  `Applying… audio restarts briefly`.
- On `ok: true`, refresh state and clear the draft.
- On `ok: true, restarted: false`, refresh state and show
  `Saved, but audio did not restart` with Retry.
- On `ok: false`, show the error and keep the draft.
- Discard resets the draft from the server chain.

- [ ] **Step 5: Add the dirty close guard**

- `close()` checks `dirty`.
- If dirty, keep the window visible and show
  `Discard unsaved changes?` with `Keep editing` and `Discard`.
- `Discard` clears the draft and hides the window.
- The bar toggle and close button both route through this guard.
- Use `keepLoaded: true` so the instance and confirmation survive a shell hide.

- [ ] **Step 6: Verify staged editing end to end**

Run these checks:

1. Open the window; add High-pass; edit Freq to 120; drag High-pass above
   RNNoise; bypass RNNoise.
2. Before Apply, run `wavemix fx state --json` — the order and bypass must be
   unchanged.
3. Click Apply.
4. Verify `state.json` order is `highpass-1`, `rnnoise-1`; RNNoise is
   `enabled: false`; High-pass `freq` is 120.
5. Verify exactly one PipeWire restart in `journalctl --user --since '1 min ago'`.
6. Verify audio and the default mic still work.
7. Close with a dirty change and verify the discard confirmation.
8. Verify `qmllint` is clean.

- [ ] **Step 7: Commit**

```bash
git add fx-plugin/FxWindow.qml
git commit -m "feat(plugin): add drag reorder and staged apply"
```

---

### Task 7: Remove the old popup and wire the bar

**Files:**
- Modify: `plugin/Panel.qml`

**Interfaces:**
- Consumes: `root.bar.shell.toggle("mnisyif.wavemix-fx")` or
  `root.bar.run("omarchy-shell shell toggle mnisyif.wavemix-fx")`.
- Produces: `openMicFx()` opens the floating window.

- [ ] **Step 1: Replace `openMicFx()`**

Change the existing function to:

```qml
function openMicFx() {
  if (root.opened) root.close()
  if (root.bar && root.bar.shell
      && typeof root.bar.shell.toggle === "function")
    root.bar.shell.toggle("mnisyif.wavemix-fx")
  else
    root.bar.run("omarchy-shell shell toggle mnisyif.wavemix-fx")
}
```

The middle-click handlers and the gear already call `root.openMicFx()`.

- [ ] **Step 2: Remove the popup and its plumbing**

Delete from `plugin/Panel.qml`:

- the `fxData`, `fxOpen`, `fxChain`, `fxPlugins`, `fxSelected`, `fxView`,
  `fxApplying`, `fxError`, `fxLoadError`, `fxControlOverrides` properties;
- all `fx*` helper functions (`fxPluginName`, `fxPluginMeta`,
  `fxControlKey`, `fxControlValue`, `fxQuantizeControl`,
  `fxControlDecimals`, `fxFormatControlValue`, `fxControlUnit`,
  `setFxControl`, `reconcileFxOverrides`, `clampFxSelection`, `selectFx`,
  `openFxAdd`, `closeFxAdd`, `fxMutate`, `fxAddEffect`, `fxToggleEffect`,
  `fxRemoveEffect`, `fxMoveEffect`, `fxShortError`, `finishFxCommand`,
  `refreshFxState`, `toggleFxMaster`, `setMicFx` if unused);
- the `fxStateProc` Process, `fxApplyWatchdog`, `fxRefreshSoon`,
  `fxOverrideExpire` timers, and the `fxPopup` `PopupCard`;
- the `FxChainRow`, `FxSettings`, `FxControlRow`, and `FxPluginRow`
  components (now in `FxWindow.qml`).

Keep `micFxOn` (from `statusData`), `FxRow`, the gear, and the master toggle.

- [ ] **Step 3: Verify the bar**

Run: `omarchy restart shell` (or wait for the plugin hot reload).
Expected:

- Middle-click either Wavemix icon opens the floating window.
- The gear on Noise suppression opens the same window.
- The gear and middle-click no longer open a popup.
- The master switch still calls `wavemix micfx toggle`.
- The mixer panel still opens and its controls work.
- `qmllint plugin/Panel.qml` is clean.

- [ ] **Step 4: Commit**

```bash
git add plugin/Panel.qml
git commit -m "refactor(plugin): move effects editing to the floating window"
```

---

### Task 8: Version bump, docs, and full verification

**Files:**
- Modify: `VERSION`
- Modify: `plugin/manifest.json`
- Modify: `fx-plugin/manifest.json`
- Modify: `bin/wavemix_fx.py` (`WAVEMIX_VERSION`)
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: everything above.
- Produces: release `1.2.0`.

- [ ] **Step 1: Bump versions**

Set `1.2.0` in:

- `VERSION`
- `bin/wavemix_fx.py` `WAVEMIX_VERSION`
- `plugin/manifest.json` `version`
- `fx-plugin/manifest.json` `version`

- [ ] **Step 2: Update docs**

`README.md`:

- Replace the Effects popup instructions with the floating window.
- Document middle-click/gear opening the window.
- Document drag reorder, staged add/remove/bypass, live controls, and Apply.
- Keep the CLI effect section; add `wavemix fx commit --stdin`.
- Note that Phase 2 (VST3/CLAP via Carla + OSC) is planned, not in 1.2.0.

`CHANGELOG.md`:

- Add `[1.2.0]` with the floating window, drag reorder, staged Apply, and
  `fx commit`.
- Note the old Effects popup removal.
- Note the host-aware model reserved for VST3/CLAP.

- [ ] **Step 3: Run the full automated suite**

Run: `python3 -m unittest discover -s tests -v`
Expected: all tests pass.

Run: `qmllint fx-plugin/FxWindow.qml plugin/Panel.qml`
Expected: no syntax errors.

Run: `omarchy plugin validate fx-plugin`
Expected: valid manifest.

- [ ] **Step 4: Install and run the manual end-to-end check**

Run: `./install.sh`
Expected: install completes; `wavemix --version` prints `wavemix 1.2.0`;
the floating window opens from both entry points.

Then verify:

1. Add High-pass, drag it to the top, bypass RNNoise, Apply.
2. `state.json` matches the window; `wavemix fx state --json` matches.
3. One audio restart; media playback continues.
4. Live RNNoise knob change updates audio without restart.
5. Close with a dirty draft prompts.
6. Reopen the window; the committed chain is shown.
7. `omarchy restart shell`; both entry points still work.
8. No duplicate windows when toggling repeatedly.

- [ ] **Step 5: Commit**

```bash
git add VERSION bin/wavemix_fx.py plugin/manifest.json fx-plugin/manifest.json README.md CHANGELOG.md
git commit -m "release: wavemix 1.2.0 effects window"
```

---

## Plan Self-Review

- **Spec coverage:** window plugin, bar wiring, drag reorder, staged
  add/remove/bypass, live controls, atomic commit, plugin metadata, error
  handling, close guard, tests, install, docs. Phase 2 is recorded in the spec
  and explicitly excluded from this plan.
- **Type consistency:** `replace_chain` mutates state and returns the chain;
  `_next_instance_id` is shared with `add_instance`; the CLI uses
  `render_to_disk` then `save_state` then `restart_audio`; the QML sends
  `{"chain": [...]}` with `instance`, `plugin`, `enabled`, `controls`.
- **Review focus coverage:** controls preservation, reorder integrity, render
  rollback, restart failure, dirty close, live-control dirty isolation, and
  watcher serialization each have a task/test or a manual check above.
